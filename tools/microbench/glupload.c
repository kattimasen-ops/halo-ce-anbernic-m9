/* the Mali blob's CPU time to make a texture: glTexImage2D a level at a time,
immutable storage (glTexStorage2D) filled with glTexSubImage2D, and
compressed (ASTC) levels, for the sizes and formats the port uploads */
#include <SDL2/SDL.h>
#include <GLES3/gl32.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TEXTURES 24

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

static int levels_of(int size)
{
	int levels = 1;

	while (size > 1)
	{
		size /= 2;
		levels++;
	}
	return levels;
}

/* bytes of a level; block: a compressed format's bytes per 4x4 block, or 0 */
static int level_bytes(int size, int bytes_per_texel, int block)
{
	if (block)
		return ((size + 3) / 4) * ((size + 3) / 4) * block;
	return size * size * bytes_per_texel;
}

static void run(const char *name, int size, GLenum internal, GLenum format, GLenum type, int bytes, int astc,
	int storage)
{
	static unsigned char pixels[1024 * 1024 * 4];
	GLuint textures[TEXTURES];
	int levels = levels_of(size), t, l;
	double start, made, finished;

	glGenTextures(TEXTURES, textures);
	glFinish();
	start = now();
	for (t = 0; t < TEXTURES; t++)
	{
		glBindTexture(GL_TEXTURE_2D, textures[t]);
		if (storage)
			glTexStorage2D(GL_TEXTURE_2D, levels, internal, size, size);
		for (l = 0; l < levels; l++)
		{
			int s = size >> l ? size >> l : 1;

			if (astc && storage)
				glCompressedTexSubImage2D(GL_TEXTURE_2D, l, 0, 0, s, s, internal, level_bytes(s, 0, astc), pixels);
			else if (astc)
				glCompressedTexImage2D(GL_TEXTURE_2D, l, internal, s, s, 0, level_bytes(s, 0, astc), pixels);
			else if (storage)
				glTexSubImage2D(GL_TEXTURE_2D, l, 0, 0, s, s, format, type, pixels);
			else
				glTexImage2D(GL_TEXTURE_2D, l, (GLint)internal, s, s, 0, format, type, pixels);
		}
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, levels - 1);
	}
	made = now();
	glFinish();
	finished = now();
	printf("%-36s %4dx%-4d %7.3f ms a texture (%7.3f with the finish), %6.1f MB/s\n", name, size, size,
		(made - start) * 1e3 / TEXTURES, (finished - start) * 1e3 / TEXTURES,
		(double)level_bytes(size, bytes, astc) * 4 / 3 * TEXTURES / (made - start) / 1e6);
	glDeleteTextures(TEXTURES, textures);
	glFinish();
}

int main(void)
{
	static const int sizes[] = { 64, 256, 512 };
	unsigned int index;

	SDL_Init(SDL_INIT_VIDEO);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
	SDL_Window *window = SDL_CreateWindow("upload", 0, 0, 640, 480, SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN);
	SDL_GLContext context = SDL_GL_CreateContext(window);

	SDL_GL_MakeCurrent(window, context);
	printf("%s\n", glGetString(GL_RENDERER));
	glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
	for (index = 0; index < sizeof(sizes) / sizeof(sizes[0]); index++)
	{
		int size = sizes[index];

		run("565 glTexImage2D", size, GL_RGB565, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, 2, 0, 0);
		run("565 glTexStorage2D+SubImage", size, GL_RGB565, GL_RGB, GL_UNSIGNED_SHORT_5_6_5, 2, 0, 1);
		run("5551 glTexImage2D", size, GL_RGB5_A1, GL_RGBA, GL_UNSIGNED_SHORT_5_5_5_1, 2, 0, 0);
		run("4444 glTexImage2D", size, GL_RGBA4, GL_RGBA, GL_UNSIGNED_SHORT_4_4_4_4, 2, 0, 0);
		run("RGBA8 glTexImage2D", size, GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 4, 0, 0);
		run("RGBA8 glTexStorage2D+SubImage", size, GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, 4, 0, 1);
		run("ASTC 4x4 glCompressedTexImage2D", size, GL_COMPRESSED_RGBA_ASTC_4x4, 0, 0, 1, 16, 0);
		run("ASTC 4x4 storage+CompressedSub", size, GL_COMPRESSED_RGBA_ASTC_4x4, 0, 0, 1, 16, 1);
		run("ETC2 RGB8 glCompressedTexImage2D", size, GL_COMPRESSED_RGB8_ETC2, 0, 0, 1, 8, 0);
	}
	SDL_GL_DeleteContext(context);
	SDL_DestroyWindow(window);
	SDL_Quit();
	return 0;
}
