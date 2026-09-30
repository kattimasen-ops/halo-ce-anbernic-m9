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

#include <linux/futex.h>
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
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
other thread reads takes it from that core's cache */
static struct
{
	uint64_t head;              /* the end of what it wrote */
	uint64_t published;         /* the end of what the consumer may read */
	uint64_t consumed;          /* consumer.consumed, when last read */
	struct command *pending;
	uint32_t sleeping;
	uint32_t frames_submitted;
} __attribute__((aligned(64))) producer;
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

static uint64_t monotonic_ns(void)
{
	struct timespec now;

	clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static void pass_end(void)
{
	uint64_t now, flushed;
	int index;

	glthread_driver_flush();
	flushed = monotonic_ns();
	glthread_driver_finish();
	now = monotonic_ns();
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
	flushed = monotonic_ns();
	glthread_driver_finish();
	now = monotonic_ns();
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
/* the game's thread's waits for the GL thread (HALO_GL_TIMING): calls that
wait for their result, room in the queue, and the frame pacing */
static struct
{
	uint64_t syncs, sync_ns;
	uint64_t room_waits, room_ns;
	uint64_t frame_waits, frame_ns;
} producer_waits;

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
	if (__atomic_load_n(&producer.sleeping, __ATOMIC_SEQ_CST))
	{
		__atomic_store_n(&producer.sleeping, 0, __ATOMIC_SEQ_CST);
		futex_wake(&producer.sleeping);
	}
}

static uint64_t wait_for_work(uint64_t position)
{
	uint64_t end;
	int spin;

	for (spin = 0; spin < SPIN_LIMIT; spin++)
	{
		end = __atomic_load_n(&producer.published, __ATOMIC_ACQUIRE);
		if (end != position)
			return end;
		relax();
	}
	for (;;)
	{
		__atomic_store_n(&consumer.sleeping, 1, __ATOMIC_SEQ_CST);
		end = __atomic_load_n(&producer.published, __ATOMIC_SEQ_CST);
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
	timing = host_gl_timing_enabled();
	for (;;)
	{
		uint64_t end = wait_for_work(position);

		while (position != end)
		{
			struct command *command = (struct command *)(ring + position % RING_SIZE);

			switch (command->type)
			{
			case _command_call:
				if (timing)
					adjacency_call((uint32_t)glthread_call_kind(command->function));
				if (pass_timing)
					pass_call(command);
				if (bind_trace && bind_frames >= 1500 && bind_frames < 1503)
				{
					const GLuint *arguments = (const GLuint *)(command + 1);
					uint64_t start = monotonic_ns(), spent;

					glthread_replay(command->function, command + 1);
					spent = monotonic_ns() - start;
					if (spent > 300000 ||
						glthread_call_kind(command->function) == _glthread_call_bind_framebuffer)
					{
						host_logf(HOST_LOG_INFO, "call: at %6.2f ms function %3u kind %d (%u %u) %7.3f ms",
							(start - bind_frame_start) / 1e6, command->function,
							glthread_call_kind(command->function), arguments[0], arguments[1], spent / 1e6);
					}
				}
				else
				glthread_replay(command->function, command + 1);
				if (pass_timing)
					draw_traced(command);
				if (command->flags & COMMAND_EXTERNAL)
				{
					/* the pointer follows the arguments, the command's last 8 bytes */
					void **external = (void **)((unsigned char *)command + command->size - sizeof(void *));

					free(*external);
				}
				break;
			case _command_sync:
			{
				const struct sync_call *call = (const struct sync_call *)(command + 1);
				uint32_t *done = call->done;

				call->run(call->context);
				__atomic_store_n(done, 1, __ATOMIC_SEQ_CST);
				futex_wake(done);
				break;
			}
			case _command_host:
			{
				const struct host_call *call = (const struct host_call *)(command + 1);

				if (bind_trace && bind_frames >= 1500 && bind_frames < 1503)
				{
					uint64_t start = monotonic_ns(), spent;

					host_operation_run(call);
					spent = monotonic_ns() - start;
					if (spent > 300000)
						host_logf(HOST_LOG_INFO, "call: at %6.2f ms host %s %7.3f ms", (start - bind_frame_start) / 1e6,
							host_operation_name(call->run), spent / 1e6);
				}
				else
					host_operation_run(call);
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

static void publish(void)
{
	__atomic_store_n(&producer.published, producer.head, __ATOMIC_SEQ_CST);
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
		for (spin_ = 0; spin_ < SPIN_LIMIT && !(condition); spin_++) \
			relax(); \
		while (!(condition)) \
		{ \
			__atomic_store_n(&producer.sleeping, 1, __ATOMIC_SEQ_CST); \
			if (condition) \
			{ \
				__atomic_store_n(&producer.sleeping, 0, __ATOMIC_SEQ_CST); \
				break; \
			} \
			futex_wait(&producer.sleeping, 1); \
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
		if (timing && !has_room(size))
		{
			uint64_t start = monotonic_ns();

			PRODUCER_WAIT(has_room(size));
			producer_waits.room_waits++;
			producer_waits.room_ns += monotonic_ns() - start;
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
	if (timing)
	{
		uint64_t start = monotonic_ns();

		wait_while_equal(&done, 0, SPIN_LIMIT * 4);
		producer_waits.syncs++;
		producer_waits.sync_ns += monotonic_ns() - start;
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
void host_gl_fence_frame(uint32_t slot);
void host_gl_wait_frame(uint32_t slot);
uint32_t host_sdl_gl_create_context(uint32_t window);
int host_sdl_gl_make_current(uint32_t window, uint32_t context);
int host_sdl_gl_set_swap_interval(int interval);
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
}

static int synced_sdl_gl_set_swap_interval(int interval)
{
	struct word_call call = { 0, 0, interval, 0 };

	glthread_sync(run_swap_interval, &call);
	return (int)call.result;
}

static void run_swap(const void *data)
{
	if (bind_trace)
	{
		uint64_t start = monotonic_ns();

		if (bind_frames >= 1500 && bind_frames < 1503)
			host_logf(HOST_LOG_INFO, "call: at %6.2f ms the swap", (start - bind_frame_start) / 1e6);
		bind_frames++;
		bind_frame_start = start;
	}
	if (pass_timing)
		pass_frame();
	host_sdl_gl_swap_window(*(const uint32_t *)data);
	__atomic_add_fetch(&consumer.frames_done, 1, __ATOMIC_SEQ_CST);
	futex_wake(&consumer.frames_done);
}

static int queued_sdl_gl_swap_window(uint32_t window)
{
	uint32_t submitted = ++producer.frames_submitted;

	glthread_host(run_swap, &window, sizeof(window));
	/* at most frames_ahead frames queued behind the one on screen: the
	counter is the futex, so that only swaps wake the game, not every
	command the GL thread makes */
	{
		uint64_t start = timing ? monotonic_ns() : 0;

		for (;;)
		{
			uint32_t done = __atomic_load_n(&consumer.frames_done, __ATOMIC_ACQUIRE);

			if (submitted - done <= frames_ahead)
				break;
			wait_while_equal(&consumer.frames_done, done, SPIN_LIMIT);
		}
		if (timing)
		{
			producer_waits.frame_waits++;
			producer_waits.frame_ns += monotonic_ns() - start;
		}
	}
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
