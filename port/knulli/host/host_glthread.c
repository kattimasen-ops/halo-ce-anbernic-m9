/*
HOST_GLTHREAD.C

The GL thread of the Knulli port. On the handheld's Cortex-A53 the Mali
driver's own work (validating state, building descriptors and job chains)
is most of a frame, and it ran on the game's thread. Here the guest's
OpenGL ES calls, and the host functions that make GL calls for it
(host_gl.c, and the context and swap functions of host_sdl2.c), are
recorded into a queue that a thread of their own replays into the driver,
so that the game prepares the next frame while the driver builds this one.

- Calls that return nothing are queued, with a copy of the memory their
  pointers refer to (the generated recording functions, glthread_gen.py),
  and the game goes on at once.
- Calls that return a value wait for the GL thread to reach them. None
  occurs in a frame's usual work: glGen* names come from a reserve that the
  GL thread keeps filled.
- The game may be at most HALO_GL_THREAD_FRAMES (default 1) frames ahead of
  the GL thread: a swap waits for the one before it.

The queue is a ring of one producer (the game's render thread) and one
consumer. Each side spins briefly before sleeping on a futex.

HALO_GL_THREAD=0 makes the calls on the game's thread, as before.
*/

#include "host.h"
#include "host_glthread.h"
#include "host_knulli.h"

#include <EGL/egl.h>
#include <fcntl.h>
#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define RING_SIZE (8u << 20)
/* larger payloads are allocated rather than queued */
#define INLINE_LIMIT (1u << 20)
/* polls before sleeping: a few microseconds, since spinning heats the
   handheld towards the temperature at which its clocks are lowered */
#define SPIN_LIMIT 500

enum
{
	_command_wrap,
	_command_call,
	_command_sync,
	_command_host,
};

#define COMMAND_EXTERNAL 1u

struct command
{
	uint32_t type;
	uint32_t flags;
	uint32_t size;          /* the whole command's, a multiple of 16 */
	uint32_t function;      /* _command_call: which */
};

struct sync_call
{
	void (*run)(void *);
	void *context;
	uint32_t *done;
};

struct host_call
{
	void (*run)(const void *data);
};

static unsigned char *ring;
static uint32_t frames_ahead = 1;
static pthread_t thread;
/* what each thread writes, on cache lines of its own: a write to a line the
other thread reads takes it from that core's cache. The producer's own
state, written with every command, is on a line the consumer never reads. */
static struct
{
	uint64_t head;              /* the end of what it wrote */
	uint64_t published;         /* producer_shared.published, as last stored */
	uint64_t consumed;          /* consumer.consumed, when last read */
	struct command *pending;
	uint32_t frames_submitted;
} __attribute__((aligned(64))) producer;
static struct
{
	uint64_t published;         /* the end of what the consumer may read */
	uint32_t sleeping;
} __attribute__((aligned(64))) producer_shared;
static struct
{
	uint64_t consumed;          /* the end of what it has done */
	uint32_t sleeping;
	uint32_t frames_done;
} __attribute__((aligned(64))) consumer;
static int started;
static int enabled = -1;

/* ---------- futexes */

static void futex_wait(uint32_t *word, uint32_t value)
{
	syscall(SYS_futex, word, FUTEX_WAIT_PRIVATE, value, NULL, NULL, 0);
}

static void futex_wake(uint32_t *word)
{
	syscall(SYS_futex, word, FUTEX_WAKE_PRIVATE, 1, NULL, NULL, 0);
}

static inline void relax(void)
{
	__asm__ volatile("yield" ::: "memory");
}

/* waits while *word is value: spins for a while, then sleeps (whoever
changes the word wakes it) */
static void wait_while_equal(uint32_t *word, uint32_t value, int spins)
{
	int spin;

	for (spin = 0; spin < spins && __atomic_load_n(word, __ATOMIC_ACQUIRE) == value; spin++)
		relax();
	while (__atomic_load_n(word, __ATOMIC_ACQUIRE) == value)
		futex_wait(word, value);
}

/* ---------- the GPU pass timer

HALO_GPU_PASS_TIMING=1 finishes the GPU's work at every change of render
target and logs the time each target's passes took, per frame: where the
GPU's time goes, which the driver cannot say otherwise (it has no timer
queries). Mali starts a pass's work when it is flushed, so each pass's time
splits into the calls that made it (issue) and the GPU's work after the
flush (gpu). The waits slow the game down; the shares are what count. */

#define PASS_SLOTS 64
#define PASS_REPORT_FRAMES 150

static int pass_timing = -1;
static struct pass
{
	GLuint framebuffer;
	uint64_t nanoseconds;       /* issue and GPU */
	uint64_t gpu_nanoseconds;
	uint32_t passes, draws, clears;
} passes[PASS_SLOTS];
static int pass_count;
static GLuint pass_framebuffer;
static uint64_t pass_start;
static uint32_t pass_draws, pass_clears, pass_frames;
/* HALO_GPU_PASS_TIMING=2: one frame's passes in order, each logged as it
ends (pass_trace_frame: after the report's frames, a frame in the middle) */
static int pass_trace;
/* HALO_GPU_PASS_TIMING=3: in that frame, the GPU's time for each draw (each
drawn by itself: the time includes a load and store of the target's tiles) */
static int draw_trace;
/* HALO_GPU_PASS_TIMING=4: in that frame, how long each change of render target
waited in the driver, with the GPU running as it does (nothing finished) */
static int bind_trace;
static uint32_t bind_frames;
static uint64_t bind_frame_start;
static uint32_t pass_copies, pass_frames_total, pass_index;

static void pass_end(void)
{
	uint64_t now, flushed;
	int index;

	glthread_driver_flush();
	flushed = host_monotonic_ns();
	glthread_driver_finish();
	now = host_monotonic_ns();
	for (index = 0; index < pass_count && passes[index].framebuffer != pass_framebuffer; index++)
		;
	if (index == pass_count && pass_count < PASS_SLOTS)
	{
		passes[pass_count].framebuffer = pass_framebuffer;
		pass_count++;
	}
	if (pass_trace && pass_frames_total == PASS_REPORT_FRAMES * 5 && pass_start)
	{
		host_logf(HOST_LOG_INFO, "trace: pass %2u framebuffer %3u %4u draws %u clears %u copies, issue %6.2f ms, gpu %6.2f ms",
			pass_index, pass_framebuffer, pass_draws, pass_clears, pass_copies, (flushed - pass_start) / 1e6,
			(now - flushed) / 1e6);
	}
	pass_index++;
	pass_copies = 0;
	if (index < pass_count)
	{
		if (pass_start)
		{
			passes[index].nanoseconds += now - pass_start;
			passes[index].gpu_nanoseconds += now - flushed;
		}
		passes[index].passes++;
		passes[index].draws += pass_draws;
		passes[index].clears += pass_clears;
	}
	pass_draws = pass_clears = 0;
	pass_start = now;
}

static void pass_call(const struct command *command)
{
	switch (glthread_call_kind(command->function))
	{
	case _glthread_call_bind_framebuffer:
	{
		const GLuint *arguments = (const GLuint *)(command + 1);

		if (arguments[0] != GL_READ_FRAMEBUFFER && arguments[1] != pass_framebuffer)
		{
			pass_end();
			pass_framebuffer = arguments[1];
		}
		break;
	}
	case _glthread_call_draw:
		pass_draws++;
		break;
	case _glthread_call_clear:
		pass_clears++;
		break;
	case _glthread_call_copy:
		pass_copies++;
		break;
	}
}

/* the longest first */
static int pass_compare(const void *a, const void *b)
{
	uint64_t first = ((const struct pass *)a)->nanoseconds, second = ((const struct pass *)b)->nanoseconds;

	return first < second ? 1 : first > second ? -1 : 0;
}

/* after a draw of the traced frame (HALO_GPU_PASS_TIMING=3) */
static void draw_traced(const struct command *command)
{
	uint64_t flushed, now;

	if (!draw_trace || pass_frames_total != PASS_REPORT_FRAMES * 5 ||
		glthread_call_kind(command->function) != _glthread_call_draw)
	{
		return;
	}
	glthread_driver_flush();
	flushed = host_monotonic_ns();
	glthread_driver_finish();
	now = host_monotonic_ns();
	host_logf(HOST_LOG_INFO, "draw: pass %2u framebuffer %3u program %4d count %6d gpu %7.3f ms",
		pass_index, pass_framebuffer, glthread_driver_integer(GL_CURRENT_PROGRAM),
		glthread_draw_count(command->function, command + 1), (now - flushed) / 1e6);
}

static void pass_frame(void)
{
	uint64_t total = 0, gpu = 0;
	int index;

	pass_end();
	pass_frames_total++;
	pass_index = 0;
	if (++pass_frames < PASS_REPORT_FRAMES)
		return;
	for (index = 0; index < pass_count; index++)
	{
		total += passes[index].nanoseconds;
		gpu += passes[index].gpu_nanoseconds;
	}
	host_logf(HOST_LOG_INFO, "gpu: %.2f ms a frame in %d targets, %.2f ms of it the GPU's", total / 1e6 / pass_frames,
		pass_count, gpu / 1e6 / pass_frames);
	qsort(passes, (size_t)pass_count, sizeof(passes[0]), pass_compare);
	for (index = 0; index < pass_count && index < 16; index++)
	{
		host_logf(HOST_LOG_INFO, "gpu:   framebuffer %3u %7.2f ms (gpu %6.2f) %5.1f passes %6.1f draws %4.1f clears",
			passes[index].framebuffer, passes[index].nanoseconds / 1e6 / pass_frames,
			passes[index].gpu_nanoseconds / 1e6 / pass_frames,
			(double)passes[index].passes / pass_frames, (double)passes[index].draws / pass_frames,
			(double)passes[index].clears / pass_frames);
	}
	memset(passes, 0, sizeof(passes));
	pass_count = 0;
	pass_frames = 0;
}

/* ---------- the host's operations' time (HALO_GL_TIMING)

The driver's functions are timed where they are resolved
(host_gl_timing.c); the operations the host queues (buffer writes, fences,
swaps) call the driver directly, and are timed here. */

#define HOST_OPERATION_SLOTS 8

static int timing;                 /* HALO_GL_TIMING, read as the thread starts */
/* the game's thread's waits for the GL thread: calls that wait for their
result, room in the queue, and the frame pacing. frame_waits has this
frame's, measured when HALO_GL_TIMING (which adds them up in producer_waits
for its report) or HALO_HITCH_LOG is on (measure_waits) */
struct waits
{
	uint64_t syncs, sync_ns;
	uint64_t room_waits, room_ns;
	uint64_t frame_waits, frame_ns;
};
static struct waits producer_waits, frame_waits;
static int measure_waits;
/* ---------- frame pacing

The game blends between its 30 Hz ticks by its clock at the start of a
frame (port/linux/game/render_interpolation.c), and the frame reaches the
display at the first refresh after the GL thread swaps it: on the
framebuffer, Mali's swap waits only while the display holds both buffers
(above 60 frames a second), and the display takes the new one as its next
refresh begins. So a frame shows the world as it was a varying time before
it is seen, its time on the two threads and up to a refresh more, and
frames begun 25 ms apart are shown 17 and 33 ms apart: motion lurches.

The H700's LCD timing controller tells where the display is in its refresh:
its debug register holds the line being sent to the panel, and a buffer
swapped is shown from the next line 0. With it each frame is given, as it
begins, the refresh it is due at: the first it can be ready for (by the
time the game's and the GL thread took to a frame's swap lately, the
second longest of eight) after the one of the frame before it. The game
times the frame by it (host_gl_frame_due), and the GL thread holds the
frame's swap until the refresh before it has begun, so that a frame ready
early is not shown early either. A frame that is late is shown at the first
refresh after its swap. Frames are not paced without the timing controller
(another device, the HDMI output, a line count that stopped), with vsync
off, or with display.frame_pacing off (the game does not ask).

HALO_PACING_LOG=1 reports every 300 frames how many refreshes the frames
stayed on screen, and how the time from the moment a frame shows the world
at (its due refresh, or unpaced its start) to the refresh it was shown at
changed from one frame to the next: motion is even while it stays the
same. */

#define FRAME_HISTORY 16
/* time the swap itself takes, before the refresh it is for begins: a swap
that took longer waited for the display */
#define SWAP_GUARD_NS 1500000ull
/* how far into the refresh before its own a held swap is made */
#define HOLD_MARGIN_NS 300000ull

/* the H700's LCD timing controller: its debug register's bits 27 to 16
hold the line being sent to the panel */
#define TCON_LCD0 0x06511000
#define TCON_DEBUG 0xFC

static volatile const uint32_t *scanout;
static uint32_t scanout_lines;
static uint64_t refresh_ns;
/* set once the line count is found stopped */
static int scanout_stopped;
/* whether swaps wait for the display: the swap interval in effect is not 0 */
static int vsync_on = 1;
static int pacing_log;

/* the latest frames, by number (producer.frames_submitted): the game's
thread notes when it began each and the refresh it is due at, the GL
thread when it reached the frame's swap */
struct frame_times
{
	uint64_t start, due, ready;
};
static struct frame_times frame_times[FRAME_HISTORY];

struct swap_call
{
	uint32_t window;
	uint32_t frame;
};

static uint32_t scanout_line(void)
{
	return scanout[TCON_DEBUG / 4] >> 16 & 0xfff;
}

/* when the refresh the display is in began, and the time now */
static uint64_t refresh_begun(uint64_t *now)
{
	uint32_t line = scanout_line();

	*now = host_monotonic_ns();
	return *now - (uint64_t)line * refresh_ns / scanout_lines;
}

/* whether the SoC is of the H616 family (the H700 is one), whose LCD timing
controller the register is */
static int scanout_soc(void)
{
	char compatible[256];
	int fd = open("/proc/device-tree/compatible", O_RDONLY);
	ssize_t length = fd < 0 ? -1 : read(fd, compatible, sizeof(compatible));

	if (fd >= 0)
		close(fd);
	return length > 0 && memmem(compatible, (size_t)length, "sun50iw9", 8) != NULL;
}

/* maps the register (read only) and measures a refresh, on the GL thread
at start-up */
static void scanout_open(void)
{
	uint64_t wraps[2] = { 0, 0 }, start, moved;
	uint32_t previous = 0, lines = 0;
	void *page = MAP_FAILED;
	int fd, count = 0;

	if (scanout_soc() && (fd = open("/dev/mem", O_RDONLY | O_SYNC)) >= 0)
	{
		page = mmap(NULL, 0x1000, PROT_READ, MAP_SHARED, fd, TCON_LCD0);
		close(fd);
	}
	if (page != MAP_FAILED)
	{
		/* two wraps of the line count, a refresh apart, and the last line;
		a count that stays for 2 ms (a line takes 32 us) is not scanning */
		scanout = page;
		start = moved = host_monotonic_ns();
		while (count < 2)
		{
			uint32_t line = scanout_line();
			uint64_t now = host_monotonic_ns();

			if (line != previous)
				moved = now;
			if (now - moved > 2000000ull || now - start > 60000000ull)
				break;
			if (line < previous)
				wraps[count++] = now;
			if (line > lines)
				lines = line;
			previous = line;
		}
	}
	if (count < 2 || lines < 100 || wraps[1] - wraps[0] < 10000000ull || wraps[1] - wraps[0] > 30000000ull)
	{
		if (page != MAP_FAILED)
			munmap(page, 0x1000);
		scanout = NULL;
		host_logf(HOST_LOG_INFO, "frames are not paced: no display timing to read");
		return;
	}
	scanout_lines = lines + 1;
	refresh_ns = wraps[1] - wraps[0];
	host_logf(HOST_LOG_INFO, "frames are paced to the display: %u lines, %.3f ms a refresh", scanout_lines,
		refresh_ns / 1e6);
}

/* host_gl_frame_due, on the game's thread as a frame begins: how long from
now until the refresh it is due at, in microseconds, or 0 */
static long long threaded_gl_frame_due(void)
{
	static uint32_t last_line, stalls;
	static uint64_t last_time;
	uint32_t frame = producer.frames_submitted + 1, line;
	uint32_t done = __atomic_load_n(&consumer.frames_done, __ATOMIC_ACQUIRE);
	const struct frame_times *previous = &frame_times[(frame - 1) % FRAME_HISTORY];
	uint64_t longest = 0, second = 0, now, begun, due;
	int index;

	if (!scanout || scanout_stopped || !vsync_on || done < FRAME_HISTORY)
		return 0;
	line = scanout_line();
	now = host_monotonic_ns();
	/* the line count stopped (the display went to another output): the same
	line again, after a time that is no whole number of refreshes */
	if (line == last_line)
	{
		uint64_t phase = (now - last_time) % refresh_ns, tolerance = 2 * refresh_ns / scanout_lines;

		if (phase > tolerance && phase < refresh_ns - tolerance && ++stalls == 3)
		{
			scanout_stopped = 1;
			host_logf(HOST_LOG_INFO, "frames are no longer paced: the display timing stopped");
			return 0;
		}
	}
	else
		stalls = 0;
	last_line = line;
	last_time = now;
	for (index = 0; index < 8; index++)
	{
		const struct frame_times *past = &frame_times[(done - (uint32_t)index) % FRAME_HISTORY];
		uint64_t latency = past->ready - past->start;

		if (latency > longest)
		{
			second = longest;
			longest = latency;
		}
		else if (latency > second)
			second = latency;
	}
	begun = now - (uint64_t)line * refresh_ns / scanout_lines;
	due = begun + (now + second + SWAP_GUARD_NS - begun + refresh_ns - 1) / refresh_ns * refresh_ns;
	if (previous->due && due < previous->due + refresh_ns)
		due = previous->due + refresh_ns;
	frame_times[frame % FRAME_HISTORY].due = due;
	return (long long)((due - now) / 1000);
}

/* on the GL thread, before a frame's swap: held until the refresh before
the one it is due at has begun (give or take a line) */
static void frame_hold(uint32_t frame)
{
	uint64_t due = frame_times[frame % FRAME_HISTORY].due, now;
	struct timespec until;

	if (!due)
		return;
	until.tv_sec = (time_t)((due - refresh_ns + HOLD_MARGIN_NS) / 1000000000ull);
	until.tv_nsec = (long)((due - refresh_ns + HOLD_MARGIN_NS) % 1000000000ull);
	while (refresh_begun(&now) + refresh_ns / 2 < due - refresh_ns)
		clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &until, NULL);
}

/* on the GL thread, a frame's swap made at swapped and done: HALO_PACING_LOG's
counts of the refresh it was shown at */
static void frame_shown(uint32_t frame, uint64_t swapped)
{
	static uint64_t previous_shown;
	static int64_t previous_lag;
	static unsigned long frames, refreshes[4], changes[4], late;
	const struct frame_times *times = &frame_times[frame % FRAME_HISTORY];
	uint64_t now, begun, shown, moment;
	int64_t lag;

	if (!scanout || !pacing_log)
		return;
	begun = refresh_begun(&now);
	/* a swap that waited for the display returns as the refresh showing it
	begins; one that did not is shown from the next */
	shown = now - swapped > SWAP_GUARD_NS ? begun : begun + refresh_ns;
	moment = times->due ? times->due : times->start;
	lag = (int64_t)(shown - moment);
	if (previous_shown)
	{
		uint64_t count = (shown - previous_shown + refresh_ns / 2) / refresh_ns;
		double change = (double)llabs(lag - previous_lag) / 1e6;

		refreshes[count <= 1 ? 0 : count == 2 ? 1 : count == 3 ? 2 : 3]++;
		changes[change < 2.0 ? 0 : change < 6.0 ? 1 : change < 12.0 ? 2 : 3]++;
		late += times->due && shown > times->due + refresh_ns / 2;
		if (++frames == 300)
		{
			host_logf(HOST_LOG_INFO, "pacing: shown for 1 refresh %lu, 2 %lu, 3 %lu, more %lu; %s, the time from "
				"what a frame shows to its showing changing by under 2 ms %lu times, 2 to 6 ms %lu, 6 to 12 ms %lu, "
				"more %lu", refreshes[0], refreshes[1], refreshes[2], refreshes[3],
				times->due ? "paced" : "not paced", changes[0], changes[1], changes[2], changes[3]);
			if (times->due)
				host_logf(HOST_LOG_INFO, "pacing: %lu of 300 frames shown after their refresh", late);
			frames = late = 0;
			memset(refreshes, 0, sizeof(refreshes));
			memset(changes, 0, sizeof(changes));
		}
	}
	previous_shown = shown;
	previous_lag = lag;
}

/* HALO_HITCH_LOG=<ms>: the frames longer than that, as each thread sees them.
The game's thread's: its waits. The GL thread's: how much of it it spent on
commands, and its slowest ones (port/linux/src/d3d8_gl.c logs the game's
side) */
static double hitch_ms;
static int hitch_on;
enum
{
	_slow_none,
	_slow_call,
	_slow_sync,
	_slow_host,
};
static struct
{
	uint64_t frame_start, busy_ns;
	unsigned int calls, skipped;
	struct
	{
		uint64_t ns;
		int kind;
		uint32_t function;              /* _slow_call's */
		void (*run)(const void *);      /* _slow_host's */
	} slowest[3];
} gl_hitch;
/* HALO_GPU_PASS_TIMING=4's frames, in which slow calls are logged */
static int call_trace;

/* the start of a command, for the hitch log and the call trace: 0 when
neither is on */
static uint64_t command_start(void)
{
	return hitch_on || call_trace ? host_monotonic_ns() : 0;
}

/* the GL thread: one command's time, for the hitch log */
static void hitch_command(int kind, uint32_t function, void (*run)(const void *), uint64_t ns)
{
	int slot;

	if (!hitch_on)
		return;
	gl_hitch.busy_ns += ns;
	gl_hitch.calls++;
	for (slot = 0; slot < 3; slot++)
	{
		if (ns > gl_hitch.slowest[slot].ns)
		{
			int move;

			for (move = 2; move > slot; move--)
				gl_hitch.slowest[move] = gl_hitch.slowest[move - 1];
			gl_hitch.slowest[slot].ns = ns;
			gl_hitch.slowest[slot].kind = kind;
			gl_hitch.slowest[slot].function = function;
			gl_hitch.slowest[slot].run = run;
			break;
		}
	}
}

static void adjacency_call(uint32_t kind);
static void run_buffer_write(const void *data);
static struct
{
	void (*run)(const void *);
	uint64_t calls, ticks;
} host_operations[HOST_OPERATION_SLOTS];

static void host_operation_run(const struct host_call *call)
{
	uint64_t start;
	int index;

	if (!timing)
	{
		call->run(call + 1);
		return;
	}
	if (call->run == run_buffer_write)
		adjacency_call(_glthread_call_geometry);
	start = host_ticks();
	call->run(call + 1);
	for (index = 0; index < HOST_OPERATION_SLOTS; index++)
	{
		if (!host_operations[index].run || host_operations[index].run == call->run)
		{
			host_operations[index].run = call->run;
			host_operations[index].calls++;
			host_operations[index].ticks += host_ticks() - start;
			break;
		}
	}
}

static const char *host_operation_name(void (*run)(const void *));

/* what comes between consecutive draws: nothing, vertex data only (buffer
writes, attribute pointers), that and uniforms, or other state. Draws with
nothing or only vertex data between them could be one draw */
static uint32_t between_draws;
static uint64_t draws_after[4];

static void adjacency_call(uint32_t kind)
{
	if (kind == _glthread_call_draw)
	{
		int category = !between_draws ? 0 : !(between_draws & ~(1u << _glthread_call_geometry)) ? 1 :
			!(between_draws & ~((1u << _glthread_call_geometry) | (1u << _glthread_call_uniform))) ? 2 : 3;

		draws_after[category]++;
		between_draws = 0;
	}
	else
	{
		between_draws |= 1u << kind;
	}
}

void glthread_timing_report(uint32_t frames)
{
	uint64_t frequency;
	int index;

	if (!timing || !frames)
		return;
	host_logf(HOST_LOG_INFO, "gl:   draws after another with nothing between %.1f, vertex data only %.1f, "
		"and uniforms %.1f, other state %.1f", (double)draws_after[0] / frames, (double)draws_after[1] / frames,
		(double)draws_after[2] / frames, (double)draws_after[3] / frames);
	memset(draws_after, 0, sizeof(draws_after));
	host_logf(HOST_LOG_INFO, "gl:   the game's thread waited: %.1f synchronous calls %.2f ms, %.1f times for room %.2f ms, "
		"for the frame before %.2f ms (a frame)", (double)producer_waits.syncs / frames,
		producer_waits.sync_ns / 1e6 / frames, (double)producer_waits.room_waits / frames,
		producer_waits.room_ns / 1e6 / frames, producer_waits.frame_ns / 1e6 / frames);
	memset(&producer_waits, 0, sizeof(producer_waits));
	frequency = host_tick_frequency();
	for (index = 0; index < HOST_OPERATION_SLOTS && host_operations[index].run; index++)
	{
		host_logf(HOST_LOG_INFO, "gl:   (host) %-21s %7.1f calls %7.3f ms", host_operation_name(host_operations[index].run),
			(double)host_operations[index].calls / frames,
			(double)host_operations[index].ticks * 1000.0 / (double)frequency / frames);
		host_operations[index].calls = 0;
		host_operations[index].ticks = 0;
	}
}

/* ---------- the consumer */

static void wake_producer(void)
{
	if (__atomic_load_n(&producer_shared.sleeping, __ATOMIC_SEQ_CST))
	{
		__atomic_store_n(&producer_shared.sleeping, 0, __ATOMIC_SEQ_CST);
		futex_wake(&producer_shared.sleeping);
	}
}

static uint64_t wait_for_work(uint64_t position)
{
	uint64_t end;
	int spin;

	for (spin = 0; spin < SPIN_LIMIT; spin++)
	{
		end = __atomic_load_n(&producer_shared.published, __ATOMIC_ACQUIRE);
		if (end != position)
			return end;
		relax();
	}
	for (;;)
	{
		__atomic_store_n(&consumer.sleeping, 1, __ATOMIC_SEQ_CST);
		end = __atomic_load_n(&producer_shared.published, __ATOMIC_SEQ_CST);
		if (end != position)
		{
			__atomic_store_n(&consumer.sleeping, 0, __ATOMIC_SEQ_CST);
			return end;
		}
		futex_wait(&consumer.sleeping, 1);
	}
}

/* the commands the consumer makes before it tells the producer the room
they took is free */
#define CONSUMED_INTERVAL 64

static void *gl_thread_main(void *unused)
{
	uint64_t position = 0;
	unsigned int count = 0;

	(void)unused;
	for (;;)
	{
		uint64_t end = wait_for_work(position);

		while (position != end)
		{
			struct command *command = (struct command *)(ring + position % RING_SIZE);

			switch (command->type)
			{
			case _command_call:
			{
				uint64_t start;

				if (timing)
					adjacency_call((uint32_t)glthread_call_kind(command->function));
				if (pass_timing)
					pass_call(command);
				start = command_start();
				glthread_replay(command->function, command + 1);
				if (start)
				{
					uint64_t spent = host_monotonic_ns() - start;

					hitch_command(_slow_call, command->function, NULL, spent);
					if (call_trace && (spent > 300000 ||
						glthread_call_kind(command->function) == _glthread_call_bind_framebuffer))
					{
						const GLuint *arguments = (const GLuint *)(command + 1);

						host_logf(HOST_LOG_INFO, "call: at %6.2f ms function %3u kind %d (%u %u) %7.3f ms",
							(start - bind_frame_start) / 1e6, command->function,
							glthread_call_kind(command->function), arguments[0], arguments[1], spent / 1e6);
					}
				}
				if (pass_timing)
					draw_traced(command);
				if (command->flags & COMMAND_EXTERNAL)
				{
					/* the pointer follows the arguments, the command's last 8 bytes */
					void **external = (void **)((unsigned char *)command + command->size - sizeof(void *));

					free(*external);
				}
				break;
			}
			case _command_sync:
			{
				const struct sync_call *call = (const struct sync_call *)(command + 1);
				uint32_t *done = call->done;
				uint64_t start = command_start();

				call->run(call->context);
				if (start)
					hitch_command(_slow_sync, 0, NULL, host_monotonic_ns() - start);
				__atomic_store_n(done, 1, __ATOMIC_SEQ_CST);
				futex_wake(done);
				break;
			}
			case _command_host:
			{
				const struct host_call *call = (const struct host_call *)(command + 1);
				uint64_t start = command_start();

				host_operation_run(call);
				if (start)
				{
					uint64_t spent = host_monotonic_ns() - start;

					hitch_command(_slow_host, 0, call->run, spent);
					if (call_trace && spent > 300000)
						host_logf(HOST_LOG_INFO, "call: at %6.2f ms host %s %7.3f ms", (start - bind_frame_start) / 1e6,
							host_operation_name(call->run), spent / 1e6);
				}
				break;
			}
			default:
				break;
			}
			position += command->size;
			if (++count % CONSUMED_INTERVAL == 0 || position == end)
			{
				__atomic_store_n(&consumer.consumed, position, __ATOMIC_SEQ_CST);
				wake_producer();
			}
		}
	}
	return NULL;
}

/* ---------- the producer */

/* the commands the producer queues before it tells the consumer of them,
in bytes. Each telling is a write to a line the consumer reads, and an
ordered one (the consumer may have gone to sleep): some 5000 calls a frame
told one by one took the game's thread about 4% of a frame. It tells the
consumer of everything before it waits for it. */
#define PUBLISH_INTERVAL 4096

static void publish(void)
{
	producer.published = producer.head;
	__atomic_store_n(&producer_shared.published, producer.head, __ATOMIC_SEQ_CST);
	if (__atomic_load_n(&consumer.sleeping, __ATOMIC_SEQ_CST))
	{
		__atomic_store_n(&consumer.sleeping, 0, __ATOMIC_SEQ_CST);
		futex_wake(&consumer.sleeping);
	}
}

/* waits until the consumer has done enough for condition to hold */
#define PRODUCER_WAIT(condition) \
	do \
	{ \
		int spin_; \
		if (!(condition)) \
			publish(); \
		for (spin_ = 0; spin_ < SPIN_LIMIT && !(condition); spin_++) \
			relax(); \
		while (!(condition)) \
		{ \
			__atomic_store_n(&producer_shared.sleeping, 1, __ATOMIC_SEQ_CST); \
			if (condition) \
			{ \
				__atomic_store_n(&producer_shared.sleeping, 0, __ATOMIC_SEQ_CST); \
				break; \
			} \
			futex_wait(&producer_shared.sleeping, 1); \
		} \
	} while (0)

/* whether the ring has size bytes free; reads the consumer's position only
when the one read last says not */
static int has_room(uint64_t size)
{
	if (RING_SIZE - (producer.head - producer.consumed) >= size)
		return 1;
	producer.consumed = __atomic_load_n(&consumer.consumed, __ATOMIC_ACQUIRE);
	return RING_SIZE - (producer.head - producer.consumed) >= size;
}

/* room for a command of size bytes, contiguous in the ring */
static struct command *reserve(uint32_t type, uint32_t size)
{
	uint64_t offset = producer.head % RING_SIZE;
	struct command *command;

	/* multiples of 16, so that the room left before the end always holds
	at least a header */
	size = (size + 15) & ~15u;
	if (offset + size > RING_SIZE)
	{
		uint32_t rest = (uint32_t)(RING_SIZE - offset);

		PRODUCER_WAIT(has_room((uint64_t)rest + size));
		command = (struct command *)(ring + offset);
		command->type = _command_wrap;
		command->flags = 0;
		command->size = rest;
		producer.head += rest;
		offset = 0;
	}
	else
	{
		if (measure_waits && !has_room(size))
		{
			uint64_t start = host_monotonic_ns();

			PRODUCER_WAIT(has_room(size));
			frame_waits.room_waits++;
			frame_waits.room_ns += host_monotonic_ns() - start;
		}
		else
		{
			PRODUCER_WAIT(has_room(size));
		}
	}
	command = (struct command *)(ring + offset);
	command->type = type;
	command->flags = 0;
	command->size = size;
	command->function = 0;
	return command;
}

static size_t round8(size_t value)
{
	return (value + 7) & ~(size_t)7;
}

void *glthread_begin(uint32_t function, size_t size, size_t payload)
{
	int external = payload > INLINE_LIMIT;
	size_t total = sizeof(struct command) + round8(size) + (external ? sizeof(void *) : round8(payload));
	struct command *command = reserve(_command_call, (uint32_t)total);

	command->function = function;
	if (external)
	{
		/* the pointer is the command's last 8 bytes */
		command->flags = COMMAND_EXTERNAL;
		*(void **)((unsigned char *)command + command->size - sizeof(void *)) = malloc(payload);
	}
	producer.pending = command;
	return command + 1;
}

void *glthread_payload(const void *call, size_t size)
{
	const struct command *command = (const struct command *)call - 1;
	unsigned char *after = (unsigned char *)call + round8(size);

	return (command->flags & COMMAND_EXTERNAL) ? *(void **)after : after;
}

void glthread_end(void)
{
	producer.head += producer.pending->size;
	producer.pending = NULL;
	if (producer.head - producer.published >= PUBLISH_INTERVAL)
		publish();
}

void glthread_sync(void (*run)(void *), void *context)
{
	uint32_t done = 0;
	struct command *command = reserve(_command_sync, (uint32_t)(sizeof(struct command) + round8(sizeof(struct sync_call))));
	struct sync_call *call = (struct sync_call *)(command + 1);

	call->run = run;
	call->context = context;
	call->done = &done;
	producer.head += command->size;
	publish();
	if (measure_waits)
	{
		uint64_t start = host_monotonic_ns();

		wait_while_equal(&done, 0, SPIN_LIMIT * 4);
		frame_waits.syncs++;
		frame_waits.sync_ns += host_monotonic_ns() - start;
	}
	else
	{
		wait_while_equal(&done, 0, SPIN_LIMIT * 4);
	}
}

/* starts recording run(data), with room for size bytes of data (what it
returns); glthread_end queues it */
static void *host_begin(void (*run)(const void *data), size_t size)
{
	struct command *command = reserve(_command_host,
		(uint32_t)(sizeof(struct command) + round8(sizeof(struct host_call)) + round8(size)));
	struct host_call *call = (struct host_call *)(command + 1);

	call->run = run;
	producer.pending = command;
	return call + 1;
}

/* queues run(data), with a copy of size bytes of data */
static void glthread_host(void (*run)(const void *data), const void *data, size_t size)
{
	memcpy(host_begin(run, size), data, size);
	glthread_end();
}

/* ---------- pixel storage, for the sizes of images */

static GLint unpack_alignment = 4;

void glthread_pixel_store(GLenum name, GLint value)
{
	if (name == GL_UNPACK_ALIGNMENT)
		unpack_alignment = value;
}

size_t glthread_image_size(GLsizei width, GLsizei height, GLsizei depth, GLenum format, GLenum type)
{
	size_t components, bytes, row;

	switch (format)
	{
	case GL_RED: case GL_RED_INTEGER: case GL_ALPHA: case GL_LUMINANCE: case GL_DEPTH_COMPONENT:
		components = 1; break;
	case GL_RG: case GL_RG_INTEGER: case GL_LUMINANCE_ALPHA:
		components = 2; break;
	case GL_RGB: case GL_RGB_INTEGER:
		components = 3; break;
	case GL_DEPTH_STENCIL:
		components = 1; break;
	default:
		components = 4; break;
	}
	switch (type)
	{
	case GL_UNSIGNED_SHORT_5_6_5: case GL_UNSIGNED_SHORT_4_4_4_4: case GL_UNSIGNED_SHORT_5_5_5_1:
		bytes = 2; components = 1; break;
	case GL_UNSIGNED_INT_24_8: case GL_UNSIGNED_INT_2_10_10_10_REV: case GL_UNSIGNED_INT_10F_11F_11F_REV:
	case GL_UNSIGNED_INT_5_9_9_9_REV:
		bytes = 4; components = 1; break;
	case GL_UNSIGNED_SHORT: case GL_SHORT: case GL_HALF_FLOAT:
		bytes = 2; break;
	case GL_UNSIGNED_INT: case GL_INT: case GL_FLOAT:
		bytes = 4; break;
	default:
		bytes = 1; break;
	}
	row = (size_t)width * components * bytes;
	if (unpack_alignment > 1)
		row = (row + (size_t)unpack_alignment - 1) / (size_t)unpack_alignment * (size_t)unpack_alignment;
	return row * (size_t)height * (size_t)(depth > 0 ? depth : 1);
}

/* ---------- reserved names */

#define RESERVE_SIZE 1024
#define RESERVE_LOW 256
#define RESERVE_REFILL 512

static struct
{
	GLuint names[RESERVE_SIZE];
	int count;
	int refilling;
} reserves[_glthread_name_kinds];
static pthread_mutex_t reserve_lock = PTHREAD_MUTEX_INITIALIZER;

static void refill(int kind, int count)
{
	GLuint fresh[RESERVE_REFILL];

	if (count > RESERVE_REFILL)
		count = RESERVE_REFILL;
	glthread_generate_names(kind, count, fresh);
	pthread_mutex_lock(&reserve_lock);
	if (reserves[kind].count + count <= RESERVE_SIZE)
	{
		memcpy(&reserves[kind].names[reserves[kind].count], fresh, (size_t)count * sizeof(GLuint));
		reserves[kind].count += count;
	}
	reserves[kind].refilling = 0;
	pthread_mutex_unlock(&reserve_lock);
}

static void run_refill(const void *data)
{
	refill(*(const int *)data, RESERVE_REFILL);
}

struct generate_call
{
	int kind;
	GLsizei n;
	GLuint *names;
};

static void run_generate(void *context)
{
	struct generate_call *call = context;

	glthread_generate_names(call->kind, call->n, call->names);
}

void glthread_reserved_names(int kind, GLsizei n, GLuint *names)
{
	int ask = 0;

	if (n <= 0)
		return;
	pthread_mutex_lock(&reserve_lock);
	if (reserves[kind].count >= n)
	{
		reserves[kind].count -= n;
		memcpy(names, &reserves[kind].names[reserves[kind].count], (size_t)n * sizeof(GLuint));
		if (reserves[kind].count < RESERVE_LOW && !reserves[kind].refilling)
			ask = reserves[kind].refilling = 1;
		pthread_mutex_unlock(&reserve_lock);
		if (ask)
			glthread_host(run_refill, &kind, sizeof(kind));
		return;
	}
	pthread_mutex_unlock(&reserve_lock);
	{
		struct generate_call call = { kind, n, names };

		glthread_sync(run_generate, &call);
	}
}

/* ---------- the host's GL functions (host_gl.c, host_sdl2.c) */

void host_gl_get_string(uint32_t name, int index, char *buffer, uint32_t size);
int host_gl_has_extension(const char *name);
uint32_t host_gl_read_buffer_word(uint32_t buffer, uint32_t offset);
void host_gl_buffer_write(uint32_t target, uint32_t offset, uint32_t size, const void *data);
void host_gl_buffer_persistent(uint32_t target, uint32_t size);
void host_gl_buffer_write_to(uint32_t buffer, uint32_t target, uint32_t offset, uint32_t size, const void *data);
void host_gl_program_build(uint32_t program, const char *cache_path, const char *vertex_source, long long vertex_hash,
	const char *fragment_source, long long fragment_hash);
int host_gl_program_load(uint32_t program, const char *cache_path);
int host_gl_program_compile(uint32_t program, const char *cache_path, const char *vertex_source, long long vertex_hash,
	const char *fragment_source, long long fragment_hash);
void host_gl_fence_frame(uint32_t slot);
void host_gl_wait_frame(uint32_t slot);
uint32_t host_sdl_gl_create_context(uint32_t window);
int host_sdl_gl_make_current(uint32_t window, uint32_t context);
int host_sdl_gl_set_swap_interval(int interval);
int host_sdl_gl_swap_interval(void);
int host_sdl_gl_swap_window(uint32_t window);

struct buffer_write
{
	uint32_t target, offset, size;
};

static void run_buffer_write(const void *data)
{
	const struct buffer_write *write = data;

	host_gl_buffer_write(write->target, write->offset, write->size, write + 1);
}

static void queued_gl_buffer_write(uint32_t target, uint32_t offset, uint32_t size, const void *data)
{
	struct buffer_write *write = host_begin(run_buffer_write, sizeof(*write) + size);

	write->target = target;
	write->offset = offset;
	write->size = size;
	memcpy(write + 1, data, size);
	glthread_end();
}

struct buffer_write_to
{
	uint32_t buffer, target, offset, size;
};

static void run_buffer_write_to(const void *data)
{
	const struct buffer_write_to *write = data;

	host_gl_buffer_write_to(write->buffer, write->target, write->offset, write->size, write + 1);
}

static void queued_gl_buffer_write_to(uint32_t buffer, uint32_t target, uint32_t offset, uint32_t size,
	const void *data)
{
	struct buffer_write_to *write = host_begin(run_buffer_write_to, sizeof(*write) + size);

	write->buffer = buffer;
	write->target = target;
	write->offset = offset;
	write->size = size;
	memcpy(write + 1, data, size);
	glthread_end();
}

/* ---------- programs built beside the GL thread

A program the guest makes (host_gl_program_build) took the GL thread about
2 ms to load from the driver's binary, and 220-250 ms to compile and link
when it had none: a stall of the frame, and of the game's thread behind it.
Threads of their own build them instead, on contexts that share the GL
thread's objects: the loader loads binaries and hands what has none to the
compiler, so that a load never waits for a compile. Until a program is
built the GL thread leaves it unbound: the draws made with it are skipped
(what it draws appears a frame or more late, the first time), and the
uniforms set for it are kept, to be set once it is bound. The generated
replay asks for that (glthread_program_use, _draw and _uniform).
HALO_ASYNC_PROGRAMS=0 builds them on the GL thread, as before. */

/* the call: its strings follow, the cache file's path, the vertex shader's
source and the fragment shader's */
struct program_build
{
	uint32_t program;
	uint32_t path_size, vertex_size, fragment_size;
	long long vertex_hash, fragment_hash;
};

/* a program being built; the call's strings follow it */
struct program_job
{
	struct program_job *next;       /* in a builder's queue */
	uint32_t done;                  /* set by the builder: built, or found it cannot be */
	uint32_t linked;
	/* the uniform calls made for it meanwhile, whole commands */
	unsigned char *deferred;
	size_t deferred_size, deferred_capacity;
	struct program_build build;
};

struct builder
{
	const char *name;
	int nice;
	pthread_mutex_t lock;
	pthread_cond_t wake;
	struct program_job *first, *last;
	EGLContext context;
	uint32_t state;                 /* 0 starting, 1 running, 2 without its context */
};

static struct builder loader = { "halo-load", 0, PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
static struct builder compiler = { "halo-compile", 5, PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER };
static int builders_running;
/* the GL thread's context, whose objects the contexts made current on other
threads share (the program builders, and the guest's texture worker) */
static EGLDisplay share_display;
static EGLContext share_context = EGL_NO_CONTEXT;
static EGLConfig share_config;
static EGLint share_attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
__thread int glthread_direct;
/* the programs being built, by name; one that cannot be stays unbuildable,
its draws skipped */
static struct program_job **jobs;
static uint32_t job_capacity;
static struct program_job unbuildable = { .done = 1 };
/* the program the guest bound last, and whether it is being built */
static uint32_t bound_program;
int glthread_program_blocked;
/* for HALO_HITCH_LOG: the programs the builders made, and the draws skipped
while they did and the frames they were in */
static uint32_t programs_built, programs_compiled;
static unsigned long skipped_draws, skipped_frames, program_frames;

static void builder_push(struct builder *builder, struct program_job *job)
{
	job->next = NULL;
	pthread_mutex_lock(&builder->lock);
	if (builder->last)
		builder->last->next = job;
	else
		builder->first = job;
	builder->last = job;
	pthread_cond_signal(&builder->wake);
	pthread_mutex_unlock(&builder->lock);
}

static struct program_job *builder_pop(struct builder *builder)
{
	struct program_job *job;

	pthread_mutex_lock(&builder->lock);
	while (!builder->first)
		pthread_cond_wait(&builder->wake, &builder->lock);
	job = builder->first;
	builder->first = job->next;
	if (!builder->first)
		builder->last = NULL;
	pthread_mutex_unlock(&builder->lock);
	return job;
}

/* on the GL thread, once its context is made */
static void share_initialize(void)
{
	EGLint config_id = 0, version = 3, count = 0;
	EGLint config_attributes[] = { EGL_CONFIG_ID, 0, EGL_NONE };

	share_display = eglGetCurrentDisplay();
	share_context = eglGetCurrentContext();
	eglQueryContext(share_display, share_context, EGL_CONFIG_ID, &config_id);
	eglQueryContext(share_display, share_context, EGL_CONTEXT_CLIENT_VERSION, &version);
	config_attributes[1] = config_id;
	share_attributes[1] = version;
	if (!eglChooseConfig(share_display, config_attributes, &share_config, 1, &count) || count != 1)
		share_context = EGL_NO_CONTEXT;
}

/* a context that shares the GL thread's objects, or EGL_NO_CONTEXT */
static EGLContext share_new(void)
{
	return share_context == EGL_NO_CONTEXT ? EGL_NO_CONTEXT :
		eglCreateContext(share_display, share_config, share_context, share_attributes);
}

/* such a context current on the calling thread, without a surface
(EGL_KHR_surfaceless_context): whether it is */
static int share_make_current(EGLContext context)
{
	return context != EGL_NO_CONTEXT && eglMakeCurrent(share_display, EGL_NO_SURFACE, EGL_NO_SURFACE, context);
}

/* host_gl_texture_thread: a shared context of its own, current on the
guest's texture worker's thread (xbox_textures.c), which then makes its GL
calls itself */
static int threaded_gl_texture_thread(void)
{
	if (!share_make_current(share_new()))
		return 0;
	glthread_direct = 1;
	return 1;
}

static void *builder_main(void *argument)
{
	struct builder *builder = argument;
	int current = share_make_current(builder->context);

	setpriority(PRIO_PROCESS, (id_t)syscall(SYS_gettid), builder->nice);
	__atomic_store_n(&builder->state, current ? 1u : 2u, __ATOMIC_SEQ_CST);
	futex_wake(&builder->state);
	if (!current)
		return NULL;
	for (;;)
	{
		struct program_job *job = builder_pop(builder);
		const char *path = (const char *)(job + 1);
		const char *vertex = path + job->build.path_size;

		if (builder == &loader)
		{
			if (!host_gl_program_load(job->build.program, path))
			{
				builder_push(&compiler, job);
				continue;
			}
			job->linked = 1;
		}
		else
		{
			job->linked = (uint32_t)host_gl_program_compile(job->build.program, path, vertex, job->build.vertex_hash,
				vertex + job->build.vertex_size, job->build.fragment_hash);
			__atomic_add_fetch(&programs_compiled, 1, __ATOMIC_RELAXED);
		}
		/* complete on this context before the GL thread's binds it */
		glFinish();
		__atomic_add_fetch(&programs_built, 1, __ATOMIC_RELAXED);
		__atomic_store_n(&job->done, 1, __ATOMIC_RELEASE);
	}
	return NULL;
}

/* on the GL thread, once its context is made: the builders, on contexts
that share its objects */
static void builders_start(void)
{
	struct builder *builders[] = { &loader, &compiler };
	const char *setting = getenv("HALO_ASYNC_PROGRAMS");
	unsigned int index = 0;

	if (builders_running || (setting && *setting == '0'))
		return;
	for (; index < 2; index++)
	{
		pthread_t builder_thread;

		builders[index]->context = share_new();
		if (builders[index]->context == EGL_NO_CONTEXT ||
			pthread_create(&builder_thread, NULL, builder_main, builders[index]) != 0)
			break;
		pthread_setname_np(builder_thread, builders[index]->name);
	}
	/* each makes its context current on its own thread */
	builders_running = index == 2;
	while (index > 0)
	{
		index--;
		wait_while_equal(&builders[index]->state, 0, SPIN_LIMIT);
		if (builders[index]->state != 1)
			builders_running = 0;
	}
	if (builders_running)
		host_logf(HOST_LOG_INFO, "programs are built by threads of their own");
	else
		host_logf(HOST_LOG_WARN, "cannot start the program builders (EGL error 0x%x): programs are built on the GL thread",
			eglGetError());
}

static void run_program_build(const void *data)
{
	const struct program_build *build = data;
	const char *strings = (const char *)(build + 1);
	struct program_job *job;
	size_t size;

	if (!builders_running)
	{
		host_gl_program_build(build->program, strings, strings + build->path_size, build->vertex_hash,
			strings + build->path_size + build->vertex_size, build->fragment_hash);
		return;
	}
	size = build->path_size + build->vertex_size + build->fragment_size;
	job = malloc(sizeof(*job) + size);
	memset(job, 0, sizeof(*job));
	job->build = *build;
	memcpy(job + 1, strings, size);
	if (build->program >= job_capacity)
	{
		uint32_t capacity = job_capacity ? job_capacity : 1024;

		while (capacity <= build->program)
			capacity *= 2;
		jobs = realloc(jobs, capacity * sizeof(*jobs));
		memset(jobs + job_capacity, 0, (capacity - job_capacity) * sizeof(*jobs));
		job_capacity = capacity;
	}
	jobs[build->program] = job;
	builder_push(&loader, job);
}

static void queued_gl_program_build(uint32_t program, const char *cache_path, const char *vertex_source,
	long long vertex_hash, const char *fragment_source, long long fragment_hash)
{
	size_t path_size = strlen(cache_path) + 1, vertex_size = strlen(vertex_source) + 1;
	size_t fragment_size = strlen(fragment_source) + 1;
	struct program_build *build = host_begin(run_program_build,
		sizeof(*build) + path_size + vertex_size + fragment_size);
	char *strings = (char *)(build + 1);

	build->program = program;
	build->path_size = (uint32_t)path_size;
	build->vertex_size = (uint32_t)vertex_size;
	build->fragment_size = (uint32_t)fragment_size;
	build->vertex_hash = vertex_hash;
	build->fragment_hash = fragment_hash;
	memcpy(strings, cache_path, path_size);
	memcpy(strings + path_size, vertex_source, vertex_size);
	memcpy(strings + path_size + vertex_size, fragment_source, fragment_size);
	glthread_end();
}

/* whether the program may be bound: it is not being built. One found not to
build becomes unbuildable */
static int program_ready(uint32_t program)
{
	struct program_job *job = program < job_capacity ? jobs[program] : NULL;

	if (!job)
		return 1;
	if (job == &unbuildable || !__atomic_load_n(&job->done, __ATOMIC_ACQUIRE))
		return 0;
	if (!job->linked)
	{
		free(job->deferred);
		free(job);
		jobs[program] = &unbuildable;
		return 0;
	}
	return 1;
}

/* binds the program, now built, and makes the uniform calls kept for it */
static void program_bind(uint32_t program)
{
	struct program_job *job = program < job_capacity ? jobs[program] : NULL;
	size_t offset;

	glthread_program_blocked = 0;
	glthread_driver_use_program(program);
	if (!job)
		return;
	jobs[program] = NULL;
	for (offset = 0; offset < job->deferred_size;)
	{
		const struct command *command = (const struct command *)(job->deferred + offset);

		glthread_replay(command->function, command + 1);
		offset += command->size;
	}
	free(job->deferred);
	free(job);
}

/* binds the bound program if it is built now: whether it could */
static int program_unblock(void)
{
	if (!program_ready(bound_program))
		return 0;
	program_bind(bound_program);
	return 1;
}

void glthread_program_use(GLuint program)
{
	bound_program = program;
	glthread_program_blocked = !program_unblock();
}

int glthread_program_draw(void)
{
	if (program_unblock())
		return 1;
	gl_hitch.skipped++;
	return 0;
}

/* a uniform call's command is kept whole (a uniform's payload is always in
the queue, never allocated) */
int glthread_program_uniform(const void *call)
{
	const struct command *command = (const struct command *)call - 1;
	struct program_job *job;

	if (program_unblock())
		return 1;
	job = jobs[bound_program];
	if (job == &unbuildable)
		return 0;
	if (job->deferred_size + command->size > job->deferred_capacity)
	{
		while (job->deferred_size + command->size > job->deferred_capacity)
			job->deferred_capacity = job->deferred_capacity ? job->deferred_capacity * 2 : 1024;
		job->deferred = realloc(job->deferred, job->deferred_capacity);
	}
	memcpy(job->deferred + job->deferred_size, command, command->size);
	job->deferred_size += command->size;
	return 0;
}

struct buffer_persistent
{
	uint32_t target, size;
};

static void run_buffer_persistent(const void *data)
{
	const struct buffer_persistent *call = data;

	host_gl_buffer_persistent(call->target, call->size);
}

static void queued_gl_buffer_persistent(uint32_t target, uint32_t size)
{
	struct buffer_persistent call = { target, size };

	glthread_host(run_buffer_persistent, &call, sizeof(call));
}

static void run_fence_frame(const void *data)
{
	host_gl_fence_frame(*(const uint32_t *)data);
}

static void queued_gl_fence_frame(uint32_t slot)
{
	glthread_host(run_fence_frame, &slot, sizeof(slot));
}

static void run_wait_frame(const void *data)
{
	host_gl_wait_frame(*(const uint32_t *)data);
}

static void queued_gl_wait_frame(uint32_t slot)
{
	glthread_host(run_wait_frame, &slot, sizeof(slot));
}

void host_gl_visibility_frame(uint32_t counters, uint32_t counter_bytes, const uint32_t *pairs, uint32_t pair_count);

struct visibility_frame
{
	uint32_t counters, counter_bytes, pair_count;
};

static void run_visibility_frame(const void *data)
{
	const struct visibility_frame *frame = data;

	host_gl_visibility_frame(frame->counters, frame->counter_bytes, (const uint32_t *)(frame + 1), frame->pair_count);
}

static void queued_gl_visibility_frame(uint32_t counters, uint32_t counter_bytes, const uint32_t *pairs,
	uint32_t pair_count)
{
	struct visibility_frame *frame = host_begin(run_visibility_frame, sizeof(*frame) + pair_count * 2 * sizeof(uint32_t));

	frame->counters = counters;
	frame->counter_bytes = counter_bytes;
	frame->pair_count = pair_count;
	memcpy(frame + 1, pairs, pair_count * 2 * sizeof(uint32_t));
	glthread_end();
}

struct string_call
{
	uint32_t name;
	int index;
	char *buffer;
	uint32_t size;
	const char *extension;
	uint32_t result;
};

static void run_get_string(void *context)
{
	struct string_call *call = context;

	host_gl_get_string(call->name, call->index, call->buffer, call->size);
}

static void synced_gl_get_string(uint32_t name, int index, char *buffer, uint32_t size)
{
	struct string_call call = { name, index, buffer, size, NULL, 0 };

	glthread_sync(run_get_string, &call);
}

static void run_has_extension(void *context)
{
	struct string_call *call = context;

	call->result = (uint32_t)host_gl_has_extension(call->extension);
}

static int synced_gl_has_extension(const char *name)
{
	struct string_call call = { 0, 0, NULL, 0, name, 0 };

	glthread_sync(run_has_extension, &call);
	return (int)call.result;
}

struct word_call
{
	uint32_t a, b;
	int c;
	uint32_t result;
};

static void run_read_buffer_word(void *context)
{
	struct word_call *call = context;

	call->result = host_gl_read_buffer_word(call->a, call->b);
}

static uint32_t synced_gl_read_buffer_word(uint32_t buffer, uint32_t offset)
{
	struct word_call call = { buffer, offset, 0, 0 };

	glthread_sync(run_read_buffer_word, &call);
	return call.result;
}

static void run_create_context(void *context)
{
	struct word_call *call = context;
	int kind;

	call->result = host_sdl_gl_create_context(call->a);
	/* the reserve of names, now that there is a context */
	if (call->result)
	{
		for (kind = 0; kind < _glthread_name_kinds; kind++)
		{
			if (!reserves[kind].count)
				refill(kind, RESERVE_REFILL);
		}
		share_initialize();
		scanout_open();
		builders_start();
	}
}

static void start(void);
static void run_swap(const void *data);

static const char *host_operation_name(void (*run)(const void *))
{
	if (run == run_buffer_write)
		return "buffer write";
	if (run == run_buffer_write_to)
		return "buffer write (named)";
	if (run == run_fence_frame)
		return "fence";
	if (run == run_wait_frame)
		return "wait for a frame";
	if (run == run_swap)
		return "swap";
	if (run == run_refill)
		return "reserve names";
	if (run == run_program_build)
		return "program build";
	return "?";
}

static uint32_t synced_sdl_gl_create_context(uint32_t window)
{
	struct word_call call = { window, 0, 0, 0 };

	start();
	glthread_sync(run_create_context, &call);
	return call.result;
}

static void run_make_current(void *context)
{
	struct word_call *call = context;

	call->result = (uint32_t)host_sdl_gl_make_current(call->a, call->b);
}

static int synced_sdl_gl_make_current(uint32_t window, uint32_t context)
{
	struct word_call call = { window, context, 0, 0 };

	glthread_sync(run_make_current, &call);
	return (int)call.result;
}

static void run_swap_interval(void *context)
{
	struct word_call *call = context;

	call->result = (uint32_t)host_sdl_gl_set_swap_interval(call->c);
	/* frames that do not wait for the display have no refresh to be due at */
	vsync_on = host_sdl_gl_swap_interval() != 0;
}

static int synced_sdl_gl_set_swap_interval(int interval)
{
	struct word_call call = { 0, 0, interval, 0 };

	glthread_sync(run_swap_interval, &call);
	return (int)call.result;
}

/* the name of one of the GL thread's slowest commands of the frame */
static const char *slow_name(int slot)
{
	switch (gl_hitch.slowest[slot].kind)
	{
	case _slow_call:
		return glthread_function_name(gl_hitch.slowest[slot].function);
	case _slow_sync:
		return "a synchronous call";
	case _slow_host:
		return host_operation_name(gl_hitch.slowest[slot].run);
	default:
		return "-";
	}
}

static void run_swap(const void *data)
{
	const struct swap_call *call = data;
	uint64_t swapped = 0;

	/* (frame pacing: when the GL thread reached the frame's swap) */
	if (scanout)
		frame_times[call->frame % FRAME_HISTORY].ready = host_monotonic_ns();
	if (bind_trace)
	{
		uint64_t start = host_monotonic_ns();

		if (bind_frames >= 1500 && bind_frames < 1503)
			host_logf(HOST_LOG_INFO, "call: at %6.2f ms the swap", (start - bind_frame_start) / 1e6);
		bind_frames++;
		bind_frame_start = start;
		call_trace = bind_frames >= 1500 && bind_frames < 1503;
	}
	if (pass_timing)
		pass_frame();
	if (hitch_on)
	{
		uint64_t now = host_monotonic_ns();

		if (gl_hitch.frame_start && (now - gl_hitch.frame_start) / 1e6 > hitch_ms)
		{
			host_logf(HOST_LOG_INFO, "hitch: GL thread %.1f ms frame, %.1f ms in %u calls; slowest %s %.1f, %s %.1f, "
				"%s %.1f; %u draws skipped", (now - gl_hitch.frame_start) / 1e6, gl_hitch.busy_ns / 1e6, gl_hitch.calls,
				slow_name(0), gl_hitch.slowest[0].ns / 1e6, slow_name(1), gl_hitch.slowest[1].ns / 1e6,
				slow_name(2), gl_hitch.slowest[2].ns / 1e6, gl_hitch.skipped);
		}
		/* the program builders' work, every 600 frames */
		skipped_draws += gl_hitch.skipped;
		if (gl_hitch.skipped)
			skipped_frames++;
		if (++program_frames % 600 == 0)
			host_logf(HOST_LOG_INFO, "programs: %u built beside the GL thread (%u compiled); %lu draws skipped, "
				"in %lu frames, while theirs were", __atomic_load_n(&programs_built, __ATOMIC_RELAXED),
				__atomic_load_n(&programs_compiled, __ATOMIC_RELAXED), skipped_draws, skipped_frames);
	}
	if (scanout)
	{
		frame_hold(call->frame);
		swapped = host_monotonic_ns();
	}
	host_sdl_gl_swap_window(call->window);
	frame_shown(call->frame, swapped);
	if (hitch_on)
	{
		memset(&gl_hitch, 0, sizeof(gl_hitch));
		gl_hitch.frame_start = host_monotonic_ns();
	}
	__atomic_add_fetch(&consumer.frames_done, 1, __ATOMIC_SEQ_CST);
	futex_wake(&consumer.frames_done);
}

static void waits_add(struct waits *total, const struct waits *frame)
{
	total->syncs += frame->syncs;
	total->sync_ns += frame->sync_ns;
	total->room_waits += frame->room_waits;
	total->room_ns += frame->room_ns;
	total->frame_waits += frame->frame_waits;
	total->frame_ns += frame->frame_ns;
}

static int queued_sdl_gl_swap_window(uint32_t window)
{
	uint32_t submitted = ++producer.frames_submitted;
	struct swap_call call = { window, submitted };
	/* when this frame began (its previous swap's wait ended), and the next */
	uint64_t start = frame_times[submitted % FRAME_HISTORY].start, waited, now;
	struct frame_times *next = &frame_times[(submitted + 1) % FRAME_HISTORY];

	glthread_host(run_swap, &call, sizeof(call));
	publish();
	/* at most frames_ahead frames queued behind the one on screen: the
	counter is the futex, so that only swaps wake the game, not every
	command the GL thread makes */
	waited = measure_waits ? host_monotonic_ns() : 0;
	for (;;)
	{
		uint32_t done = __atomic_load_n(&consumer.frames_done, __ATOMIC_ACQUIRE);

		if (submitted - done <= frames_ahead)
			break;
		wait_while_equal(&consumer.frames_done, done, SPIN_LIMIT);
	}
	now = host_monotonic_ns();
	next->start = now;
	next->due = 0;
	if (measure_waits)
	{
		frame_waits.frame_waits++;
		frame_waits.frame_ns += now - waited;
		if (timing)
			waits_add(&producer_waits, &frame_waits);
		if (hitch_on && start && (now - start) / 1e6 > hitch_ms)
		{
			host_logf(HOST_LOG_INFO, "hitch: game thread %.1f ms frame; waited %.1f ms for room in the queue (%u times), "
				"%.1f ms in %u synchronous calls, %.1f ms for the frame before", (now - start) / 1e6,
				frame_waits.room_ns / 1e6, (unsigned int)frame_waits.room_waits, frame_waits.sync_ns / 1e6,
				(unsigned int)frame_waits.syncs, (now - waited) / 1e6);
		}
		memset(&frame_waits, 0, sizeof(frame_waits));
	}
	/* for the profiler: where each frame ends among its samples */
	if (start && host_profile_sampling())
		host_profile_mark(submitted, (uint32_t)((now - start) / 1000));
	return 1;
}

/* ---------- start-up */

static int glthread_enabled(void)
{
	if (enabled < 0)
	{
		const char *setting = getenv("HALO_GL_THREAD");
		const char *frames = getenv("HALO_GL_THREAD_FRAMES");
		const char *timing = getenv("HALO_GPU_PASS_TIMING");
		const char *hitch = getenv("HALO_HITCH_LOG");
		const char *pacing = getenv("HALO_PACING_LOG");

		hitch_ms = hitch ? atof(hitch) : 0.0;
		hitch_on = hitch_ms > 0.0;
		pacing_log = pacing && *pacing && *pacing != '0';

		enabled = !(setting && *setting == '0');
		pass_timing = timing && *timing && *timing != '0';
		pass_trace = timing && (*timing == '2' || *timing == '3');
		draw_trace = timing && *timing == '3';
		bind_trace = timing && *timing == '4';
		if (bind_trace)
			pass_timing = 0;
		if (frames && *frames)
			frames_ahead = (uint32_t)atoi(frames);
	}
	return enabled;
}

static void start(void)
{
	if (started)
		return;
	ring = mmap(NULL, RING_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
	if (ring == MAP_FAILED)
		host_fatal("cannot make the GL thread's queue");
	timing = host_gl_timing_enabled();
	measure_waits = timing || hitch_on;
	if (pthread_create(&thread, NULL, gl_thread_main, NULL) != 0)
		host_fatal("cannot start the GL thread");
	pthread_setname_np(thread, "halo-gl");
	started = 1;
	host_logf(HOST_LOG_INFO, "GL thread started (%u frame%s ahead)", frames_ahead, frames_ahead == 1 ? "" : "s");
}

static void skipped_call(void)
{
}

void *host_import_wrap(const char *name, void *function)
{
	static const struct
	{
		const char *name;
		void *function;
	} host_functions[] =
	{
		{ "host_gl_get_string", (void *)synced_gl_get_string },
		{ "host_gl_has_extension", (void *)synced_gl_has_extension },
		{ "host_gl_read_buffer_word", (void *)synced_gl_read_buffer_word },
		{ "host_gl_buffer_write", (void *)queued_gl_buffer_write },
		{ "host_gl_buffer_persistent", (void *)queued_gl_buffer_persistent },
		{ "host_gl_program_build", (void *)queued_gl_program_build },
		{ "host_gl_texture_thread", (void *)threaded_gl_texture_thread },
		{ "host_gl_frame_due", (void *)threaded_gl_frame_due },
		{ "host_gl_buffer_write_to", (void *)queued_gl_buffer_write_to },
		{ "host_gl_fence_frame", (void *)queued_gl_fence_frame },
		{ "host_gl_wait_frame", (void *)queued_gl_wait_frame },
		{ "host_gl_visibility_frame", (void *)queued_gl_visibility_frame },
		{ "host_sdl_gl_create_context", (void *)synced_sdl_gl_create_context },
		{ "host_sdl_gl_make_current", (void *)synced_sdl_gl_make_current },
		{ "host_sdl_gl_set_swap_interval", (void *)synced_sdl_gl_set_swap_interval },
		{ "host_sdl_gl_swap_window", (void *)queued_sdl_gl_swap_window },
	};
	unsigned long index;

	if (function && !strncmp(name, "hostgl_", 7))
	{
		/* HALO_DEBUG_SKIP_GL=glA,glB: the GL thread does not make these
		calls, to measure what they cost the calls after them */
		const char *skip = getenv("HALO_DEBUG_SKIP_GL");
		size_t length = strlen(name + 7);

		/* HALO_GL_TIMING: the driver's function, timed */
		function = host_gl_wrap(name + 7, function);
		if (!glthread_enabled())
			return function;

		while (skip && *skip)
		{
			if (!strncmp(skip, name + 7, length) && (skip[length] == ',' || !skip[length]))
			{
				host_logf(HOST_LOG_WARN, "debug: not making %s", name + 7);
				function = (void *)skipped_call;
				break;
			}
			skip = strchr(skip, ',');
			if (skip)
				skip++;
		}
		return glthread_record_function(name + 7, function);
	}
	if (!function || !glthread_enabled())
		return function;
	for (index = 0; index < sizeof(host_functions) / sizeof(host_functions[0]); index++)
	{
		if (!strcmp(host_functions[index].name, name))
			return host_functions[index].function;
	}
	return function;
}
