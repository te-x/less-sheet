#pragma once
#include <adwaita.h>
#include <lsg_document.h>

/* The caller closes this dialog before replacing/closing its document. */
AdwDialog *lsg_metadata_dialog_new (LsgDocument *doc, const char *name);
