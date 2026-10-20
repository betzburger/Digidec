// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Dünne C-Schicht über GTK 4: Fenster mit Zeichenfläche, Zeigerereignisse, Eingabefelder, Zeitgeber.
// Alle Zeiger sind `void *`, damit Swift keine GTK-Typhierarchie nachbilden muss.
#ifndef DIGIDEC_GTK_H
#define DIGIDEC_GTK_H

#include <cairo.h>

typedef struct {
    /// `fresh`: Die Fläche ist neu (oder hat die Größe gewechselt) und muss vollständig gezeichnet werden; sonst enthält sie noch das letzte Bild
    void (*draw)(void *user, cairo_t *cr, int width, int height, int fresh);
    void (*pressed)(void *user, int button, double x, double y);
    void (*released)(void *user, int button, double x, double y);
    void (*motion)(void *user, double x, double y);
    void (*leave)(void *user);
    int (*scroll)(void *user, double dx, double dy, unsigned state);
    int (*key)(void *user, unsigned keyval, unsigned state, unsigned codepoint);
    void (*closed)(void *user);
    void (*tick)(void *user);
} DGCallbacks;

typedef struct { void *window; void *area; void *fixed; } DGWindow;

/// Anwendung (eine Instanz je Sitzung: ein zweiter Aufruf reicht seine URLs über D-Bus an die laufende weiter und endet).
/// `open` bekommt je übergebene URL einen Aufruf, `activate` den Start ohne URL. SIGTERM, SIGINT und SIGHUP beenden `dg_app_run`.
void *dg_app_new(const char *id, void (*activate)(void *user), void (*open)(void *user, const char *uri), void *user);
int dg_app_run(void *app, int argc, char **argv);
void dg_app_quit(void *app);
/// Aktion `app.<name>` mit optionalem Tastenkürzel (GTK-Schreibweise, z. B. "<Control>q"). Mit `initial_state` ist sie eine
/// Auswahl mit Zeichenkettenwert (Menüpunkte „app.<name>::<wert>“); `value` ist dann der gewählte Wert, sonst NULL.
void dg_app_add_action(void *app, const char *name, const char *accel, const char *initial_state,
                       void (*callback)(void *user, const char *value), void *user);
/// Menümodell; `append_section`/`append_submenu` übernehmen das übergebene Teilmenü
void *dg_menu_new(void);
void dg_menu_append(void *menu, const char *label, const char *detailed_action);
void dg_menu_append_section(void *menu, void *section);
void dg_menu_append_submenu(void *menu, const char *label, void *submenu);
/// Kopfleiste mit Menüknopf (übernimmt das Menü)
void dg_window_set_menu(void *window, void *menu, const char *tooltip);
/// Rückfrage mit zwei Knöpfen; `choice` 0 = erster, 1 = zweiter oder abgebrochen
void dg_alert(void *window, const char *message, const char *detail, const char *first, const char *second,
              void (*callback)(void *user, int choice), void *user);
DGWindow dg_window_new(void *app, const char *title, int width, int height, const DGCallbacks *callbacks, void *user);
void dg_window_present(void *window);
/// Schließt das Fenster wie der Knopf in der Titelleiste (close-request, danach destroy)
void dg_window_close(void *window);
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

/// Schreibt den Aufrufstapel des aufrufenden Fadens nach stderr (Entwicklungshilfe)
void dg_dump_stack(void);

#endif
