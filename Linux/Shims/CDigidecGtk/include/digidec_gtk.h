// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Dünne C-Schicht über GTK 4: Fenster mit Zeichenfläche, Zeigerereignisse, Eingabefelder, Zeitgeber.
// Alle Zeiger sind `void *`, damit Swift keine GTK-Typhierarchie nachbilden muss.
#ifndef DIGIDEC_GTK_H
#define DIGIDEC_GTK_H

#include <cairo.h>

typedef struct {
    void (*draw)(void *user, cairo_t *cr, int width, int height);
    void (*pressed)(void *user, int button, double x, double y);
    void (*released)(void *user, int button, double x, double y);
    void (*motion)(void *user, double x, double y);
    void (*leave)(void *user);
    int (*scroll)(void *user, double dx, double dy);
    int (*key)(void *user, unsigned keyval, unsigned state, unsigned codepoint);
    void (*closed)(void *user);
    void (*tick)(void *user);
} DGCallbacks;

typedef struct { void *window; void *area; void *fixed; } DGWindow;

void *dg_app_new(const char *id, void (*activate)(void *user), void *user);
int dg_app_run(void *app);
DGWindow dg_window_new(void *app, const char *title, int width, int height, const DGCallbacks *callbacks, void *user);
void dg_window_present(void *window);
void dg_window_set_title(void *window, const char *title);
void dg_queue_draw(void *widget);

void dg_install_css(const char *css);

void *dg_entry_new(const char *placeholder, int secure, double alignment, const char *family, double px, int plain,
                   void (*changed)(void *user), void (*activate)(void *user), void *user);
void *dg_textview_new(const char *family, double px, void (*changed)(void *user), void *user);
void dg_field_place(void *fixed, void *field, double x, double y, int width, int height, int isNew);
void dg_field_remove(void *fixed, void *field);
void dg_field_set_enabled(void *field, int enabled);
char *dg_field_get_text(void *field, int multiline);
void dg_field_set_text(void *field, int multiline, const char *text);
void dg_field_focus(void *field);
void dg_free(void *pointer);

/// Dateiauswahl (modal); liefert den Pfad oder NULL
char *dg_file_dialog(void *window, const char *title, int save, int folder, const char *suggested_name);
void dg_clipboard_set(void *widget, const char *text);

#endif
