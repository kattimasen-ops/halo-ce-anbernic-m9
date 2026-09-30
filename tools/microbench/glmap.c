/* the CPU's cost of writing into a persistently mapped GL buffer on the Mali
blob: per call and per byte, flushed or not, for different mapping flags */
#include <SDL2/SDL.h>
#include <GLES3/gl32.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

#define GL_MAP_PERSISTENT_BIT_EXT 0x0040
#define GL_MAP_COHERENT_BIT_EXT 0x0080
typedef void (*storage_function)(GLenum, GLsizeiptr, const void *, GLbitfield);

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

enum { SIZE = 16 << 20, CALLS = 4000 };
static unsigned char source[65536];

static void run(const char *name, unsigned char *mapping, int flush, unsigned size)
{
	unsigned offset = 0;
	double start = now(), elapsed;
	for (int i = 0; i < CALLS; i++)
	{
		if (offset + size > SIZE)
			offset = 0;
		memcpy(mapping + offset, source, size);
		if (flush)
			glFlushMappedBufferRange(GL_ARRAY_BUFFER, offset, size);
		offset += (size + 255) & ~255u;
	}
	elapsed = now() - start;
	printf("  %-22s %5u bytes: %6.2f us a write, %7.1f MB/s\n", name, size, elapsed * 1e6 / CALLS,
		(double)size * CALLS / elapsed / 1e6);
}

static void mapping_test(storage_function storage, const char *name, GLbitfield flags, GLbitfield map_flags)
{
	GLuint buffer;
	unsigned char *mapping;
	unsigned sizes[] = { 64, 256, 960, 4096 };
	glGenBuffers(1, &buffer);
	glBindBuffer(GL_ARRAY_BUFFER, buffer);
	storage(GL_ARRAY_BUFFER, SIZE, NULL, flags);
	mapping = glMapBufferRange(GL_ARRAY_BUFFER, 0, SIZE, map_flags);
	if (!mapping)
	{
		printf("%s: no mapping (0x%x)\n", name, glGetError());
		return;
	}
	printf("%s\n", name);
	for (unsigned s = 0; s < sizeof(sizes) / sizeof(sizes[0]); s++)
	{
		if (map_flags & GL_MAP_FLUSH_EXPLICIT_BIT)
			run("copy + flush", mapping, 1, sizes[s]);
		run("copy only", mapping, 0, sizes[s]);
	}
	{
		/* reading shows whether the CPU caches the mapping */
		volatile unsigned sum = 0;
		double start = now();
		for (int i = 0; i < (1 << 20); i += 4)
			sum += *(unsigned *)(mapping + i);
		printf("  read 1 MB: %.2f ms\n", (now() - start) * 1e3);
	}
	glUnmapBuffer(GL_ARRAY_BUFFER);
	glDeleteBuffers(1, &buffer);
}

int main(void)
{
	SDL_Init(SDL_INIT_VIDEO);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
	SDL_Window *window = SDL_CreateWindow("map", 0, 0, 640, 480, SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN);
	SDL_GLContext context = SDL_GL_CreateContext(window);
	SDL_GL_MakeCurrent(window, context);
	storage_function storage = (storage_function)SDL_GL_GetProcAddress("glBufferStorageEXT");
	printf("%s, glBufferStorageEXT %p\n", glGetString(GL_RENDERER), (void *)storage);
	for (unsigned i = 0; i < sizeof(source); i++)
		source[i] = (unsigned char)i;
	{
		static unsigned char heap[SIZE];
		double start = now();
		for (int i = 0; i < CALLS; i++)
			memcpy(heap + (i * 1024) % (SIZE - 4096), source, 960);
		printf("ordinary memory: %.2f us a 960-byte copy\n", (now() - start) * 1e6 / CALLS);
	}
	if (!storage)
		return 1;
	mapping_test(storage, "write, persistent, explicit flush",
		GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT_EXT,
		GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT_EXT | GL_MAP_FLUSH_EXPLICIT_BIT);
	mapping_test(storage, "write + read, persistent, explicit flush (the port's)",
		GL_MAP_WRITE_BIT | GL_MAP_READ_BIT | GL_MAP_PERSISTENT_BIT_EXT,
		GL_MAP_WRITE_BIT | GL_MAP_READ_BIT | GL_MAP_PERSISTENT_BIT_EXT | GL_MAP_FLUSH_EXPLICIT_BIT);
	mapping_test(storage, "write, persistent, coherent",
		GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT_EXT | GL_MAP_COHERENT_BIT_EXT,
		GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT_EXT | GL_MAP_COHERENT_BIT_EXT);
	mapping_test(storage, "write + read, persistent, coherent",
		GL_MAP_WRITE_BIT | GL_MAP_READ_BIT | GL_MAP_PERSISTENT_BIT_EXT | GL_MAP_COHERENT_BIT_EXT,
		GL_MAP_WRITE_BIT | GL_MAP_READ_BIT | GL_MAP_PERSISTENT_BIT_EXT | GL_MAP_COHERENT_BIT_EXT);
	return 0;
}
