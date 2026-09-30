/* per-draw CPU cost of the Mali blob under different state changes */
#include <SDL2/SDL.h>
#include <GLES3/gl32.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

static GLuint shader(GLenum type, const char *source)
{
	GLuint s = glCreateShader(type);
	GLint ok;
	glShaderSource(s, 1, &source, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok)
	{
		char log[2048];
		glGetShaderInfoLog(s, sizeof(log), NULL, log);
		printf("shader: %s\n", log);
	}
	return s;
}

static GLuint program(int constants, int ubo)
{
	char vs[4096], fs[2048];
	GLuint p = glCreateProgram();
	if (ubo)
		snprintf(vs, sizeof(vs), "#version 300 es\nlayout(std140) uniform C { vec4 c[%d]; };\n"
			"in vec4 a0; in vec4 a1; in vec4 a2; in vec4 a3; in vec4 a4; in vec4 a5; in vec4 a6;\n"
			"out vec4 v; uniform highp int k;\n"
			"void main() { gl_Position = a0 * c[k] + c[1] + a1 * 0.001 + a2 * 0.001 + a3 * 0.001 + a4 * 0.001 + a5 * 0.001; v = a6; }\n",
			constants);
	else
		snprintf(vs, sizeof(vs), "#version 300 es\nuniform vec4 c[%d];\n"
			"in vec4 a0; in vec4 a1; in vec4 a2; in vec4 a3; in vec4 a4; in vec4 a5; in vec4 a6;\n"
			"out vec4 v; uniform highp int k;\n"
			"void main() { gl_Position = a0 * c[k] + c[1] + a1 * 0.001 + a2 * 0.001 + a3 * 0.001 + a4 * 0.001 + a5 * 0.001; v = a6; }\n",
			constants);
	snprintf(fs, sizeof(fs), "#version 300 es\nprecision mediump float; in vec4 v; out vec4 o;\n"
		"uniform sampler2D t0, t1, t2, t3; uniform vec4 p[8];\n"
		"void main() { o = v * texture(t0, v.xy) + texture(t1, v.yx) + texture(t2, v.zw) + texture(t3, v.wz) + p[3]; }\n");
	glAttachShader(p, shader(GL_VERTEX_SHADER, vs));
	glAttachShader(p, shader(GL_FRAGMENT_SHADER, fs));
	for (int i = 0; i < 7; i++)
	{
		char name[8];
		snprintf(name, sizeof(name), "a%d", i);
		glBindAttribLocation(p, i, name);
	}
	glLinkProgram(p);
	glUseProgram(p);
	for (int i = 0; i < 4; i++)
	{
		char name[8];
		snprintf(name, sizeof(name), "t%d", i);
		glUniform1i(glGetUniformLocation(p, name), i);
	}
	return p;
}

enum { DRAWS = 2000 };
static GLuint textures[8], programs[4], ubo;
static GLint cloc[4], ploc[4];

static void run(const char *name, int mode)
{
	float values[16] = { 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, 0, 1, 0, 1, 0, 1 };
	double start, submitted, finished;
	glFinish();
	start = now();
	for (int i = 0; i < DRAWS; i++)
	{
		GLuint prog = programs[0];
		if (mode & 8)
		{
			prog = programs[i & 1];
			glUseProgram(prog);
		}
		if (mode & 1)
		{
			values[0] = (float)(i & 7) * 0.01f;
			glUniform4fv(cloc[(mode & 8) ? (i & 1) : 0] + 4, 4, values);
		}
		if (mode & 64)
		{
			values[0] = (float)(i & 7) * 0.01f;
			glUniform4fv(ploc[0], 1, values);
		}
		if (mode & 2)
		{
			for (int a = 0; a < 7; a++)
				glVertexAttribPointer(a, 4, GL_FLOAT, GL_FALSE, 112, (const void *)(uintptr_t)((i & 3) * 112 * 4 + a * 16));
		}
		if (mode & 4)
		{
			for (int t = 0; t < 4; t++)
			{
				glActiveTexture(GL_TEXTURE0 + t);
				glBindTexture(GL_TEXTURE_2D, textures[(t + i) & 7]);
			}
		}
		if (mode & 16)
			glBindBufferRange(GL_UNIFORM_BUFFER, 0, ubo, (GLintptr)((i & 15) * 256), 192 * 16);
		if (mode & 32)
			glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, (const void *)(uintptr_t)((i & 63) * 12));
		else
			glDrawRangeElementsBaseVertex(GL_TRIANGLES, 0, 3, 6, GL_UNSIGNED_SHORT,
				(const void *)(uintptr_t)((i & 63) * 12), 0);
	}
	submitted = now();
	glFinish();
	finished = now();
	printf("%-44s %6.2f us/draw submit, %6.2f us/draw total\n", name, (submitted - start) * 1e6 / DRAWS,
		(finished - start) * 1e6 / DRAWS);
}

int main(void)
{
	SDL_Init(SDL_INIT_VIDEO);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
	SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 2);
	SDL_Window *window = SDL_CreateWindow("bench", 0, 0, 640, 480, SDL_WINDOW_OPENGL | SDL_WINDOW_FULLSCREEN);
	SDL_GLContext context = SDL_GL_CreateContext(window);
	SDL_GL_MakeCurrent(window, context);
	SDL_GL_SetSwapInterval(0);
	printf("%s\n", glGetString(GL_RENDERER));

	GLuint vbo, ibo, vao;
	static float vertices[64 * 28 * 4];
	static unsigned short indices[64 * 6];
	for (int i = 0; i < (int)(sizeof(vertices) / 4); i++)
		vertices[i] = (float)(i % 13) * 0.01f;
	for (int i = 0; i < 64 * 6; i++)
		indices[i] = (unsigned short)(i % 4);
	glGenVertexArrays(1, &vao);
	glBindVertexArray(vao);
	glGenBuffers(1, &vbo);
	glBindBuffer(GL_ARRAY_BUFFER, vbo);
	glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
	glGenBuffers(1, &ibo);
	glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
	glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(indices), indices, GL_STATIC_DRAW);
	for (int a = 0; a < 7; a++)
	{
		glEnableVertexAttribArray(a);
		glVertexAttribPointer(a, 4, GL_FLOAT, GL_FALSE, 112, (const void *)(uintptr_t)(a * 16));
	}
	const char *mode = getenv("TEXMODE") ? getenv("TEXMODE") : "plain";
	printf("texture mode %s\n", mode);
	glGenTextures(8, textures);
	for (int t = 0; t < 8; t++)
	{
		static unsigned char pixels[256 * 256 * 4];
		int levels = strstr(mode, "mip") ? 9 : 1;
		glBindTexture(GL_TEXTURE_2D, textures[t]);
		for (int l = 0; l < levels; l++)
			glTexImage2D(GL_TEXTURE_2D, l, GL_RGBA8, 256 >> l, 256 >> l, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, levels > 1 ? GL_LINEAR_MIPMAP_LINEAR : GL_LINEAR);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_BASE_LEVEL, 0);
		glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, levels - 1);
		if (strstr(mode, "swizzle"))
		{
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_R, GL_BLUE);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, GL_RED);
		}
		if (strstr(mode, "identity"))
		{
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_R, GL_RED);
			glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_SWIZZLE_B, GL_BLUE);
		}
	}
	if (strstr(mode, "sampler"))
	{
		GLuint samplers[4];
		glGenSamplers(4, samplers);
		for (int t = 0; t < 4; t++)
		{
			glSamplerParameteri(samplers[t], GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
			glSamplerParameteri(samplers[t], GL_TEXTURE_MAG_FILTER, GL_LINEAR);
			glSamplerParameterf(samplers[t], GL_TEXTURE_MIN_LOD, 0.0f);
			glBindSampler(t, samplers[t]);
		}
	}
	for (int t = 0; t < 4; t++)
	{
		glActiveTexture(GL_TEXTURE0 + t);
		glBindTexture(GL_TEXTURE_2D, strstr(mode, "unbound") ? 0 : textures[t]);
	}
	glGenBuffers(1, &ubo);
	glBindBuffer(GL_UNIFORM_BUFFER, ubo);
	glBufferData(GL_UNIFORM_BUFFER, 16 * 256 + 192 * 16, NULL, GL_DYNAMIC_DRAW);
	glViewport(0, 0, 640, 480);

	int sizes[] = { 192, 16 };
	for (int s = 0; s < 2; s++)
	{
		programs[0] = program(sizes[s], 0);
		programs[1] = program(sizes[s], 0);
		for (int i = 0; i < 2; i++)
		{
			cloc[i] = glGetUniformLocation(programs[i], "c");
			ploc[i] = glGetUniformLocation(programs[i], "p");
		}
		glUseProgram(programs[0]);
		printf("-- uniform vec4 c[%d]\n", sizes[s]);
		run("warm up", 0);
		run("draws only (range, base vertex)", 0);
		run("draws only (glDrawElements)", 32);
		run("+ vertex uniform change", 1);
		run("+ fragment uniform change", 64);
		run("+ 7 attribute pointers", 2);
		run("+ 4 texture binds", 4);
		run("+ program switch", 8);
		run("+ uniforms + attributes + textures", 1 | 2 | 4);
		run("+ all + program switch", 1 | 2 | 4 | 8);
	}
	programs[0] = program(192, 1);
	programs[1] = program(192, 1);
	glUniformBlockBinding(programs[0], glGetUniformBlockIndex(programs[0], "C"), 0);
	glUniformBlockBinding(programs[1], glGetUniformBlockIndex(programs[1], "C"), 0);
	glUseProgram(programs[0]);
	printf("-- uniform block C { vec4 c[192]; }\n");
	run("warm up", 16);
	run("+ block range per draw", 16);
	run("+ block range + attributes + textures", 16 | 2 | 4);
	SDL_GL_SwapWindow(window);
	return 0;
}
