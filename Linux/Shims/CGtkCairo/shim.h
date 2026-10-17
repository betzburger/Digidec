// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Peter Betz und Mitwirkende
// Cairo-Zeichenbefehle und ein paar GTK-Aufrufe für die eigenen Zeichenflächen des Linux-Frontends
#include <gtk/gtk.h>
#include <cairo.h>
#include <pango/pangocairo.h>

static inline void digidec_queue_draw(void *widget) { gtk_widget_queue_draw((GtkWidget *)widget); }
