// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
#include "digidec_gtk.h"
#include <gtk/gtk.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>
#include <execinfo.h>

typedef struct { DGCallbacks cb; void *user; } Ctx;

// Eigene Zeichenfläche: Die Oberfläche wird direkt in ein Bild gezeichnet und als Textur an die GPU gegeben.
// (GtkDrawingArea reicht eine Aufzeichnungsfläche, die GTK danach noch einmal vollständig per CPU abspielt: doppelte Arbeit.)
typedef struct { GtkWidget parent; Ctx *ctx; cairo_surface_t *backing; int bw, bh; double bscale; } DGCanvas;
typedef struct { GtkWidgetClass parent_class; } DGCanvasClass;
G_DEFINE_TYPE(DGCanvas, dg_canvas, GTK_TYPE_WIDGET)

static void dg_canvas_snapshot(GtkWidget *widget, GtkSnapshot *snapshot) {
    DGCanvas *self = (DGCanvas *)widget;
    int w = gtk_widget_get_width(widget), h = gtk_widget_get_height(widget);
    if (w <= 0 || h <= 0 || !self->ctx || !self->ctx->cb.draw) return;
    double scale = 1;
    GtkNative *native = gtk_widget_get_native(widget);
    if (native) { GdkSurface *surface = gtk_native_get_surface(native); if (surface) scale = gdk_surface_get_scale(surface); }
    int pw = (int)ceil(w * scale), ph = (int)ceil(h * scale);
    // Das Bild bleibt zwischen den Frames erhalten: gezeichnet wird nur, was sich geändert hat
    int fresh = 0;
    if (!self->backing || self->bw != pw || self->bh != ph || self->bscale != scale) {
        if (self->backing) cairo_surface_destroy(self->backing);
        self->backing = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, pw, ph);
        cairo_surface_set_device_scale(self->backing, pw / (double)w, ph / (double)h);
        self->bw = pw; self->bh = ph; self->bscale = scale;
        fresh = 1;
    }
    cairo_t *cr = cairo_create(self->backing);
    self->ctx->cb.draw(self->ctx->user, cr, w, h, fresh);
    cairo_destroy(cr);
    cairo_surface_flush(self->backing);
    int stride = cairo_image_surface_get_stride(self->backing);
    // Die Textur bekommt eine Kopie, weil das Bild im nächsten Frame weiter verändert wird
    GBytes *bytes = g_bytes_new(cairo_image_surface_get_data(self->backing), (gsize)stride * ph);
    GdkTexture *texture = gdk_memory_texture_new(pw, ph, GDK_MEMORY_B8G8R8A8_PREMULTIPLIED, bytes, stride);
    graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, w, h);
    gtk_snapshot_append_texture(snapshot, texture, &bounds);
    g_object_unref(texture);
    g_bytes_unref(bytes);
}
static void dg_canvas_class_init(DGCanvasClass *klass) { GTK_WIDGET_CLASS(klass)->snapshot = dg_canvas_snapshot; }
static void dg_canvas_init(DGCanvas *self) { self->ctx = NULL; self->backing = NULL; self->bw = self->bh = 0; self->bscale = 0; }

static void on_pressed(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Ctx *c = data; (void)n;
    if (c->cb.pressed) c->cb.pressed(c->user, (int)gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g)), x, y);
}
static void on_released(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    Ctx *c = data; (void)n;
    if (c->cb.released) c->cb.released(c->user, (int)gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g)), x, y);
}
static void on_motion(GtkEventControllerMotion *m, double x, double y, gpointer data) { Ctx *c = data; (void)m; if (c->cb.motion) c->cb.motion(c->user, x, y); }
static void on_leave(GtkEventControllerMotion *m, gpointer data) { Ctx *c = data; (void)m; if (c->cb.leave) c->cb.leave(c->user); }
static gboolean on_scroll(GtkEventControllerScroll *s, double dx, double dy, gpointer data) {
    Ctx *c = data;
    unsigned state = (unsigned)gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(s));
    return c->cb.scroll ? c->cb.scroll(c->user, dx, dy, state) : FALSE;
}
static gboolean on_key(GtkEventControllerKey *k, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    Ctx *c = data; (void)k; (void)keycode;
    return c->cb.key ? c->cb.key(c->user, keyval, (unsigned)state, gdk_keyval_to_unicode(keyval)) : FALSE;
}
static gboolean on_close(GtkWindow *w, gpointer data) { Ctx *c = data; (void)w; if (c->cb.closed) c->cb.closed(c->user); return FALSE; }
static gboolean on_tick(gpointer data) { Ctx *c = data; if (c->cb.tick) c->cb.tick(c->user); return G_SOURCE_CONTINUE; }

typedef struct { void (*activate)(void *); void *user; } AppCtx;
static void app_activate(GtkApplication *app, gpointer data) { AppCtx *c = data; (void)app; c->activate(c->user); }

void *dg_app_new(const char *id, void (*activate)(void *user), void *user) {
    GtkApplication *app = gtk_application_new(id, G_APPLICATION_DEFAULT_FLAGS);
    AppCtx *c = malloc(sizeof *c); c->activate = activate; c->user = user;
    g_signal_connect(app, "activate", G_CALLBACK(app_activate), c);
    return app;
}

int dg_app_run(void *app) { return g_application_run(G_APPLICATION(app), 0, NULL); }

DGWindow dg_window_new(void *app, const char *title, int width, int height, const DGCallbacks *callbacks, void *user) {
    Ctx *c = malloc(sizeof *c); c->cb = *callbacks; c->user = user;
    GtkWidget *window = gtk_application_window_new(GTK_APPLICATION(app));
    gtk_window_set_title(GTK_WINDOW(window), title);
    gtk_window_set_default_size(GTK_WINDOW(window), width, height);
    GtkWidget *overlay = gtk_overlay_new();
    GtkWidget *area = g_object_new(dg_canvas_get_type(), NULL);
    ((DGCanvas *)area)->ctx = c;
    gtk_widget_set_hexpand(area, TRUE); gtk_widget_set_vexpand(area, TRUE); gtk_widget_set_focusable(area, TRUE);
    gtk_overlay_set_child(GTK_OVERLAY(overlay), area);
    GtkWidget *fixed = gtk_fixed_new();
    gtk_widget_set_can_target(fixed, FALSE);
    gtk_overlay_add_overlay(GTK_OVERLAY(overlay), fixed);
    gtk_window_set_child(GTK_WINDOW(window), overlay);

    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect(click, "pressed", G_CALLBACK(on_pressed), c);
    g_signal_connect(click, "released", G_CALLBACK(on_released), c);
    gtk_widget_add_controller(area, GTK_EVENT_CONTROLLER(click));

    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(on_motion), c);
    g_signal_connect(motion, "enter", G_CALLBACK(on_motion), c);
    g_signal_connect(motion, "leave", G_CALLBACK(on_leave), c);
    gtk_widget_add_controller(area, motion);

    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll, "scroll", G_CALLBACK(on_scroll), c);
    gtk_widget_add_controller(area, scroll);

    GtkEventController *keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, GTK_PHASE_CAPTURE);
    g_signal_connect(keys, "key-pressed", G_CALLBACK(on_key), c);
    gtk_widget_add_controller(window, keys);

    g_signal_connect(window, "close-request", G_CALLBACK(on_close), c);
    g_timeout_add(16, on_tick, c);
    DGWindow w = { window, area, fixed };
    return w;
}

void dg_window_present(void *window) { gtk_window_present(GTK_WINDOW(window)); }
void dg_window_set_title(void *window, const char *title) { gtk_window_set_title(GTK_WINDOW(window), title); }
void dg_queue_draw(void *widget) { gtk_widget_queue_draw(GTK_WIDGET(widget)); }

void dg_install_css(const char *css) {
    GtkCssProvider *p = gtk_css_provider_new();
    gtk_css_provider_load_from_string(p, css);
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(p), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
}

typedef struct { void (*changed)(void *); void (*activate)(void *); void *user; } FieldCtx;
static void field_changed(GtkEditable *e, gpointer data) { FieldCtx *c = data; (void)e; if (c->changed) c->changed(c->user); }
static void field_buffer_changed(GtkTextBuffer *b, gpointer data) { FieldCtx *c = data; (void)b; if (c->changed) c->changed(c->user); }
static void field_activate(GtkEntry *e, gpointer data) { FieldCtx *c = data; (void)e; if (c->activate) c->activate(c->user); }

static void apply_font(GtkWidget *w, const char *family, double px, int entry) {
    PangoAttrList *attrs = pango_attr_list_new();
    PangoFontDescription *d = pango_font_description_new();
    pango_font_description_set_family(d, family);
    pango_font_description_set_absolute_size(d, px * PANGO_SCALE);
    pango_attr_list_insert(attrs, pango_attr_font_desc_new(d));
    pango_font_description_free(d);
    if (entry) gtk_entry_set_attributes(GTK_ENTRY(w), attrs);
    pango_attr_list_unref(attrs);
}

void *dg_entry_new(const char *placeholder, int secure, double alignment, const char *family, double px, int plain,
                   void (*changed)(void *user), void (*activate)(void *user), void *user) {
    GtkWidget *entry = gtk_entry_new();
    gtk_widget_add_css_class(entry, plain ? "digidec-entry-plain" : "digidec-entry");
    if (secure) gtk_entry_set_visibility(GTK_ENTRY(entry), FALSE);
    gtk_entry_set_placeholder_text(GTK_ENTRY(entry), placeholder);
    gtk_editable_set_alignment(GTK_EDITABLE(entry), (float)alignment);
    apply_font(entry, family, px, 1);
    FieldCtx *c = malloc(sizeof *c); c->changed = changed; c->activate = activate; c->user = user;
    g_signal_connect(entry, "changed", G_CALLBACK(field_changed), c);
    g_signal_connect(entry, "activate", G_CALLBACK(field_activate), c);
    return entry;
}

void *dg_textview_new(const char *family, double px, void (*changed)(void *user), void *user) {
    GtkWidget *view = gtk_text_view_new();
    gtk_text_view_set_wrap_mode(GTK_TEXT_VIEW(view), GTK_WRAP_WORD_CHAR);
    gtk_widget_add_css_class(view, "digidec-editor");
    GtkWidget *scroller = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroller), view);
    g_object_set_data(G_OBJECT(scroller), "dg-inner", view);
    char css[128]; snprintf(css, sizeof css, ".digidec-editor { font-family: \"%s\"; font-size: %.0fpx; }", family, px);
    GtkCssProvider *p = gtk_css_provider_new(); gtk_css_provider_load_from_string(p, css);
    gtk_style_context_add_provider(gtk_widget_get_style_context(view), GTK_STYLE_PROVIDER(p), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    FieldCtx *c = malloc(sizeof *c); c->changed = changed; c->activate = NULL; c->user = user;
    g_signal_connect(gtk_text_view_get_buffer(GTK_TEXT_VIEW(view)), "changed", G_CALLBACK(field_buffer_changed), c);
    return scroller;
}

void dg_field_place(void *fixed, void *field, double x, double y, int width, int height, int isNew) {
    if (isNew) gtk_fixed_put(GTK_FIXED(fixed), GTK_WIDGET(field), x, y); else gtk_fixed_move(GTK_FIXED(fixed), GTK_WIDGET(field), x, y);
    gtk_widget_set_size_request(GTK_WIDGET(field), width, height);
}
void dg_field_remove(void *fixed, void *field) { gtk_fixed_remove(GTK_FIXED(fixed), GTK_WIDGET(field)); }
void dg_field_set_enabled(void *field, int enabled) { gtk_widget_set_sensitive(GTK_WIDGET(field), enabled); }
static GtkWidget *inner(void *field, int multiline) { return multiline ? g_object_get_data(G_OBJECT(field), "dg-inner") : GTK_WIDGET(field); }
char *dg_field_get_text(void *field, int multiline) {
    if (multiline) {
        GtkTextBuffer *b = gtk_text_view_get_buffer(GTK_TEXT_VIEW(inner(field, 1)));
        GtkTextIter s, e; gtk_text_buffer_get_bounds(b, &s, &e);
        return gtk_text_buffer_get_text(b, &s, &e, FALSE);
    }
    return g_strdup(gtk_editable_get_text(GTK_EDITABLE(field)));
}
void dg_field_set_text(void *field, int multiline, const char *text) {
    if (multiline) gtk_text_buffer_set_text(gtk_text_view_get_buffer(GTK_TEXT_VIEW(inner(field, 1))), text, -1);
    else gtk_editable_set_text(GTK_EDITABLE(field), text);
}
void dg_field_focus(void *field) { gtk_widget_grab_focus(GTK_WIDGET(field)); }
void dg_free(void *p) { g_free(p); }

typedef struct { GMainLoop *loop; char *result; GtkFileDialog *dialog; } DialogState;
static void dialog_done(GObject *source, GAsyncResult *res, gpointer data) {
    DialogState *s = data; GError *err = NULL; GFile *file = NULL;
    GtkFileDialog *d = GTK_FILE_DIALOG(source);
    if (g_object_get_data(G_OBJECT(d), "dg-save")) file = gtk_file_dialog_save_finish(d, res, &err);
    else if (g_object_get_data(G_OBJECT(d), "dg-folder")) file = gtk_file_dialog_select_folder_finish(d, res, &err);
    else file = gtk_file_dialog_open_finish(d, res, &err);
    if (file) { s->result = g_file_get_path(file); g_object_unref(file); }
    if (err) g_error_free(err);
    g_main_loop_quit(s->loop);
}
char *dg_file_dialog(void *window, const char *title, int save, int folder, const char *suggested_name) {
    GtkFileDialog *d = gtk_file_dialog_new();
    gtk_file_dialog_set_title(d, title);
    if (save) { g_object_set_data(G_OBJECT(d), "dg-save", GINT_TO_POINTER(1)); if (suggested_name) gtk_file_dialog_set_initial_name(d, suggested_name); }
    if (folder) g_object_set_data(G_OBJECT(d), "dg-folder", GINT_TO_POINTER(1));
    DialogState s = { g_main_loop_new(NULL, FALSE), NULL, d };
    if (save) gtk_file_dialog_save(d, GTK_WINDOW(window), NULL, dialog_done, &s);
    else if (folder) gtk_file_dialog_select_folder(d, GTK_WINDOW(window), NULL, dialog_done, &s);
    else gtk_file_dialog_open(d, GTK_WINDOW(window), NULL, dialog_done, &s);
    g_main_loop_run(s.loop);
    g_main_loop_unref(s.loop); g_object_unref(d);
    return s.result;
}

void dg_clipboard_set(void *widget, const char *text) {
    gdk_clipboard_set_text(gtk_widget_get_clipboard(GTK_WIDGET(widget)), text);
}

void dg_dump_stack(void) { void *frames[64]; int n = backtrace(frames, 64); backtrace_symbols_fd(frames, n, 2); }
