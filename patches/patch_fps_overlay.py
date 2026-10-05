#!/usr/bin/env python3
"""
In-Game-FPS-Overlay fuer den M9 Pro (RK3326 / Mali-G31).

Fuegt in port/linux/src/d3d8_gl.c ein kleines gelbes FPS-Zaehler-Overlay
ein, das nach dem Blit auf den Default-Framebuffer gezeichnet wird, mit
einer 3x5-Bitmap-Schrift.

Zwei neue Eintraege in port_config.c:
  display.fps_overlay         (bool, Standard false, HALO_FPS_OVERLAY)
  display.fps_overlay_corner  (int,  Standard 3,     HALO_FPS_OVERLAY_CORNER)

Ecken: 0 = oben links, 1 = oben rechts, 2 = unten links, 3 = unten rechts.

Idempotent.
"""

import os
import sys


OVERLAY_BLOCK = r'''
#ifdef HALO_ANDROID
/* ---------- in-game FPS overlay ------------------------------------------

A small yellow counter drawn in the corner of the default framebuffer at
the end of each frame, after the game's picture has been blitted and
before the swap. A 3x5 bitmap font is baked into the code as a table of
rows; each row uses its low three bits for the three pixels of a glyph.

Disabled by default: display.fps_overlay = true (HALO_FPS_OVERLAY=1)
enables it. Position with display.fps_overlay_corner (0..3). */

static int fps_overlay_enabled;
static int fps_overlay_corner = 3;
static int fps_overlay_ready;    /* 0 = not tried, -1 = failed, 1 = ready */
static GLuint fps_overlay_program;
static GLuint fps_overlay_vao;
static GLuint fps_overlay_vbo;
static GLint fps_overlay_color;

#define FPS_OVERLAY_WINDOW 60
static double fps_overlay_times[FPS_OVERLAY_WINDOW];
static int fps_overlay_index;
static int fps_overlay_filled;
static unsigned long long fps_overlay_last_ns;

static const unsigned char fps_overlay_glyphs[13][5] =
{
    { 0x07, 0x05, 0x05, 0x05, 0x07 },  /* 0 */
    { 0x02, 0x06, 0x02, 0x02, 0x07 },  /* 1 */
    { 0x07, 0x01, 0x07, 0x04, 0x07 },  /* 2 */
    { 0x07, 0x01, 0x07, 0x01, 0x07 },  /* 3 */
    { 0x05, 0x05, 0x07, 0x01, 0x01 },  /* 4 */
    { 0x07, 0x04, 0x07, 0x01, 0x07 },  /* 5 */
    { 0x07, 0x04, 0x07, 0x05, 0x07 },  /* 6 */
    { 0x07, 0x01, 0x01, 0x01, 0x01 },  /* 7 */
    { 0x07, 0x05, 0x07, 0x05, 0x07 },  /* 8 */
    { 0x07, 0x05, 0x07, 0x01, 0x07 },  /* 9 */
    { 0x07, 0x04, 0x07, 0x04, 0x04 },  /* F */
    { 0x07, 0x05, 0x07, 0x04, 0x04 },  /* P */
    { 0x07, 0x04, 0x07, 0x01, 0x07 },  /* S */
};

static int fps_overlay_glyph_for(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c == 'F' || c == 'f') return 10;
    if (c == 'P' || c == 'p') return 11;
    if (c == 'S' || c == 's') return 12;
    return -1;
}

static GLuint fps_overlay_compile(GLenum type, const char *source)
{
    GLuint s = glCreateShader(type);
    GLint ok = 0;

    glShaderSource(s, 1, &source, NULL);
    glCompileShader(s);
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok)
    {
        char log[1024];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        platform_log("fps_overlay: shader failed: %s", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static void fps_overlay_initialize(void)
{
    static const char *vertex_source =
        "#version 300 es\n"
        "layout(location = 0) in vec2 position;\n"
        "void main()\n{\n"
        "    gl_Position = vec4(position, 0.0, 1.0);\n"
        "}\n";
    static const char *fragment_source =
        "#version 300 es\n"
        "precision mediump float;\n"
        "uniform vec4 color;\n"
        "layout(location = 0) out vec4 out_color;\n"
        "void main()\n{\n"
        "    out_color = color;\n"
        "}\n";
    GLuint vs, fs;
    GLint ok;

    if (fps_overlay_ready)
        return;
    fps_overlay_ready = -1;
    vs = fps_overlay_compile(GL_VERTEX_SHADER, vertex_source);
    fs = fps_overlay_compile(GL_FRAGMENT_SHADER, fragment_source);
    if (!vs || !fs)
        return;
    fps_overlay_program = glCreateProgram();
    glAttachShader(fps_overlay_program, vs);
    glAttachShader(fps_overlay_program, fs);
    glLinkProgram(fps_overlay_program);
    glDeleteShader(vs);
    glDeleteShader(fs);
    glGetProgramiv(fps_overlay_program, GL_LINK_STATUS, &ok);
    if (!ok)
    {
        char log[1024];
        glGetProgramInfoLog(fps_overlay_program, sizeof(log), NULL, log);
        platform_log("fps_overlay: link failed: %s", log);
        return;
    }
    fps_overlay_color = glGetUniformLocation(fps_overlay_program, "color");
    glGenVertexArrays(1, &fps_overlay_vao);
    glGenBuffers(1, &fps_overlay_vbo);
    glBindVertexArray(fps_overlay_vao);
    glBindBuffer(GL_ARRAY_BUFFER, fps_overlay_vbo);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), (const void *)0);
    glBindVertexArray(0);
    fps_overlay_ready = 1;
    platform_log("fps overlay: shader ready");
}

static void fps_overlay_configure(void)
{
    fps_overlay_enabled = config_boolean("display.fps_overlay");
    fps_overlay_corner = config_integer("display.fps_overlay_corner");
    if (fps_overlay_corner < 0 || fps_overlay_corner > 3)
        fps_overlay_corner = 3;
    if (fps_overlay_enabled)
        platform_log("fps overlay: enabled (corner %d)", fps_overlay_corner);
}

static void fps_overlay_frame(void)
{
    struct timespec now;
    unsigned long long ns;

    if (!fps_overlay_enabled)
        return;
    clock_gettime(CLOCK_MONOTONIC, &now);
    ns = (unsigned long long)now.tv_sec * 1000000000ULL + (unsigned long long)now.tv_nsec;
    if (fps_overlay_last_ns)
    {
        double dt = (double)(ns - fps_overlay_last_ns) / 1e9;
        if (dt > 0.0 && dt < 1.0)
        {
            fps_overlay_times[fps_overlay_index] = dt;
            fps_overlay_index = (fps_overlay_index + 1) % FPS_OVERLAY_WINDOW;
            if (fps_overlay_index == 0)
                fps_overlay_filled = 1;
        }
    }
    fps_overlay_last_ns = ns;
}

static void fps_overlay_draw(int window_width, int window_height)
{
    static float vertices[4096];
    char text[32];
    double total = 0.0;
    int samples, i, len, count = 0;
    float origin_x, origin_y, pixel_size = 2.0f, text_w, text_h, margin = 4.0f;
    int saved_program = 0, saved_vao = 0, saved_viewport[4] = { 0, 0, 0, 0 };

    if (!fps_overlay_enabled || fps_overlay_ready != 1)
        return;
    if (!window_width || !window_height)
        return;
    samples = fps_overlay_filled ? FPS_OVERLAY_WINDOW : fps_overlay_index;
    if (!samples)
        return;
    for (i = 0; i < samples; i++)
        total += fps_overlay_times[i];
    {
        double fps = samples / total;
        if (fps > 999.0) fps = 999.0;
        snprintf(text, sizeof(text), "%.0f FPS", fps);
    }
    len = (int)strlen(text);
    text_w = (float)(len * 4) * pixel_size;
    text_h = 5.0f * pixel_size;
    switch (fps_overlay_corner)
    {
    case 0: origin_x = margin; origin_y = margin; break;
    case 1: origin_x = (float)window_width - text_w - margin; origin_y = margin; break;
    case 2: origin_x = margin; origin_y = (float)window_height - text_h - margin; break;
    default:
        origin_x = (float)window_width - text_w - margin;
        origin_y = (float)window_height - text_h - margin;
        break;
    }

    for (i = 0; i < len; i++)
    {
        int g = fps_overlay_glyph_for(text[i]);
        int row, col, cursor = i * 4;

        if (g < 0)
            continue;
        for (row = 0; row < 5; row++)
        {
            for (col = 0; col < 3; col++)
            {
                if (fps_overlay_glyphs[g][row] & (1 << (2 - col)))
                {
                    float x = origin_x + (cursor + col) * pixel_size;
                    float y = origin_y + row * pixel_size;
                    float x1 = x + pixel_size, y1 = y + pixel_size;
                    float nx0 = x / window_width * 2.0f - 1.0f;
                    float nx1 = x1 / window_width * 2.0f - 1.0f;
                    float ny0 = 1.0f - y / window_height * 2.0f;
                    float ny1 = 1.0f - y1 / window_height * 2.0f;
                    if (count + 12 > (int)(sizeof(vertices) / sizeof(vertices[0])))
                        break;
                    vertices[count++] = nx0; vertices[count++] = ny0;
                    vertices[count++] = nx1; vertices[count++] = ny0;
                    vertices[count++] = nx0; vertices[count++] = ny1;
                    vertices[count++] = nx1; vertices[count++] = ny0;
                    vertices[count++] = nx1; vertices[count++] = ny1;
                    vertices[count++] = nx0; vertices[count++] = ny1;
                }
            }
        }
    }
    if (!count)
        return;

    glGetIntegerv(GL_CURRENT_PROGRAM, &saved_program);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &saved_vao);
    glGetIntegerv(GL_VIEWPORT, saved_viewport);

    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_CULL_FACE);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glUseProgram(fps_overlay_program);
    glUniform4f(fps_overlay_color, 1.0f, 1.0f, 0.0f, 1.0f);
    glViewport(0, 0, window_width, window_height);
    glBindVertexArray(fps_overlay_vao);
    glBindBuffer(GL_ARRAY_BUFFER, fps_overlay_vbo);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(count * sizeof(float)), vertices, GL_STREAM_DRAW);
    glDrawArrays(GL_TRIANGLES, 0, count / 2);
    glBindVertexArray((GLuint)saved_vao);
    glUseProgram((GLuint)saved_program);
    glViewport(saved_viewport[0], saved_viewport[1], saved_viewport[2], saved_viewport[3]);

    /* the overlay changed GL state behind the renderer's cache: make it
    re-apply everything on the next draw */
    xgpu_gl_state_invalidate();
}
#endif  /* HALO_ANDROID */
'''


CONFIG_ENTRIES_ANCHOR = '''\t{ "display.frame_pacing", _config_boolean, "true", "HALO_FRAME_PACING", _environment_value, _platform_android,
\t\t"Show each frame at the display refresh it was drawn for, holding one that\\n"
\t\t"is ready early, so that motion advances as the screen shows it (the\\n"
\t\t"Knulli host, on an H700 handheld's own screen); false shows each frame\\n"
\t\t"as soon as it is drawn." },
'''

CONFIG_ENTRIES_ADDITION = '''\t{ "display.frame_pacing", _config_boolean, "true", "HALO_FRAME_PACING", _environment_value, _platform_android,
\t\t"Show each frame at the display refresh it was drawn for, holding one that\\n"
\t\t"is ready early, so that motion advances as the screen shows it (the\\n"
\t\t"Knulli host, on an H700 handheld's own screen); false shows each frame\\n"
\t\t"as soon as it is drawn." },
\t{ "display.fps_overlay", _config_boolean, "false", "HALO_FPS_OVERLAY", _environment_value, _platform_android,
\t\t"Draw a small FPS counter in the corner of the screen (the M9 Pro\\n"
\t\t"port's own, written in GLSL; nothing to do with the game's HUD)." },
\t{ "display.fps_overlay_corner", _config_integer, "3", "HALO_FPS_OVERLAY_CORNER", _environment_value,
\t\t_platform_android,
\t\t"Where the FPS counter goes: 0 top-left, 1 top-right, 2 bottom-left,\\n"
\t\t"3 bottom-right (the default)." },
'''


def patch_d3d8_gl(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "d3d8_gl.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden")
        return False
    with open(path) as f:
        text = f.read()

    if "fps_overlay_enabled" in text:
        print("d3d8_gl.c: FPS-Overlay bereits vorhanden – überspringe.")
        return True

    # 1) Overlay-Block vor gl_initialize
    anchor = "static void gl_initialize(void)"
    if anchor not in text:
        print("FEHLER: gl_initialize-Anker fehlt")
        return False
    text = text.replace(anchor, OVERLAY_BLOCK + "\n" + anchor, 1)

    # 2) Konfiguration + Initialisierung in gl_initialize aufrufen
    ready_anchor = "\txgpu_gl_state_invalidate();\n\tdevice.gl_ready = TRUE;\n}"
    ready_new = "\txgpu_gl_state_invalidate();\n\tfps_overlay_configure();\n\tfps_overlay_initialize();\n\tdevice.gl_ready = TRUE;\n}"
    if ready_anchor in text:
        text = text.replace(ready_anchor, ready_new, 1)
    else:
        print("WARNUNG: gl_ready-Marker nicht gefunden (Konfiguration wird nicht aufgerufen)")

    # 3) Frame-Aufzeichnung in D3DDevice_Present (top)
    present_anchor = "void WINAPI D3DDevice_Present(CONST RECT *source_rectangle, CONST RECT *destination_rectangle,\n\tvoid *unused, void *unused2)\n{\n\tstatic long screenshot_every = -1;\n"
    present_new = present_anchor + "\tfps_overlay_frame();\n"
    if present_anchor in text:
        text = text.replace(present_anchor, present_new, 1)
    else:
        print("WARNUNG: D3DDevice_Present-Anker nicht gefunden")

    # 4) Zeichnen nach dem Blit, vor dem Swap
    swap_anchor = "\t\tglBlitFramebuffer(0, 0, (GLint)back_buffer->target.gl_width, (GLint)back_buffer->target.gl_height,\n\t\t\tx, y + height, x + width, y, GL_COLOR_BUFFER_BIT, GL_LINEAR);\n\t\tplatform_video_swap();"
    swap_new = "\t\tglBlitFramebuffer(0, 0, (GLint)back_buffer->target.gl_width, (GLint)back_buffer->target.gl_height,\n\t\t\tx, y + height, x + width, y, GL_COLOR_BUFFER_BIT, GL_LINEAR);\n#ifdef HALO_ANDROID\n\t\tfps_overlay_draw(window_width, window_height);\n#endif\n\t\tplatform_video_swap();"
    if swap_anchor in text:
        text = text.replace(swap_anchor, swap_new, 1)
    else:
        print("WARNUNG: Blit/Swap-Anker nicht gefunden")

    with open(path, "w") as f:
        f.write(text)
    print("d3d8_gl.c: FPS-Overlay eingebaut.")
    return True


def patch_port_config(src_root):
    path = os.path.join(src_root, "port", "linux", "src", "port_config.c")
    if not os.path.exists(path):
        print(f"FEHLER: {path} nicht gefunden")
        return False
    with open(path) as f:
        text = f.read()

    if "HALO_FPS_OVERLAY_CORNER" in text:
        print("port_config.c: FPS-Eintraege bereits vorhanden – überspringe.")
        return True
    if CONFIG_ENTRIES_ANCHOR not in text:
        print("WARNUNG: display.frame_pacing-Eintrag nicht gefunden; "
              "FPS-Eintraege werden nicht hinzugefügt.")
        return False
    text = text.replace(CONFIG_ENTRIES_ANCHOR, CONFIG_ENTRIES_ADDITION, 1)
    with open(path, "w") as f:
        f.write(text)
    print("port_config.c: display.fps_overlay + fps_overlay_corner eingebaut.")
    return True


def apply_patch(src_root):
    print("== Patch 10: In-Game-FPS-Overlay ==")
    ok_d3d8 = patch_d3d8_gl(src_root)
    ok_config = patch_port_config(src_root)
    if not (ok_d3d8 or ok_config):
        print("FEHLER: keine der Änderungen konnte angewendet werden.")
        sys.exit(1)


if __name__ == "__main__":
    apply_patch(sys.argv[1] if len(sys.argv) > 1 else ".")
