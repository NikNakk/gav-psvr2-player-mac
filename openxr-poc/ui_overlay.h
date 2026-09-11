#pragma once

#include "controller_input.h"

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GAVUIOverlay GAVUIOverlay;

typedef enum GAVUIActionType {
    GAV_UI_ACTION_NONE = 0,
    GAV_UI_ACTION_PLAY_PAUSE = 1,
    GAV_UI_ACTION_RECENTER = 2,
    GAV_UI_ACTION_OPEN_PATH = 3,
} GAVUIActionType;

typedef struct GAVUIAction {
    GAVUIActionType type;
    const char *path;
} GAVUIAction;

#ifdef __OBJC__
GAVUIOverlay *gav_ui_create(id<MTLDevice> device, const char *currentPath);
id<MTLTexture> gav_ui_texture(GAVUIOverlay *ui);
#endif

void gav_ui_destroy(GAVUIOverlay *ui);
void gav_ui_set_current_path(GAVUIOverlay *ui, const char *path);
void gav_ui_update(GAVUIOverlay *ui,
                   double currentSeconds,
                   double durationSeconds,
                   int playing);
int gav_ui_visible(GAVUIOverlay *ui);

// Handles UI-only controller actions. Menu always toggles the panel. When the
// panel is visible, D-pad/Cross/Circle are consumed by the UI; shoulders are
// deliberately left alone so the player's existing +/-15 s seek remains usable.
int gav_ui_process_controller(GAVUIOverlay *ui,
                              const GAVControllerSnapshot *snapshot,
                              GAVUIAction *action);

#ifdef __cplusplus
}
#endif
