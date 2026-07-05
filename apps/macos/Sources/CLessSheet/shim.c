/* CLessSheet — SwiftPM C target vendoring the workspace-frozen core header.
 * include/lesssheet.h is a checked-in relative symlink to ../../api/lesssheet.h
 * (single source of truth; never copy the header). Including it here makes
 * every `swift build` verify that the header is self-contained C99. */
#include "lesssheet.h"
