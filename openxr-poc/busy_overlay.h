#pragma once

#ifdef __OBJC__
#import <Metal/Metal.h>

// Paints an animated status card directly into the existing headset UI texture.
// This is used while media resolution/download runs off the render thread.
void gav_busy_overlay_draw(id<MTLTexture> texture,
                           const char *title,
                           const char *detail,
                           double timeSeconds);
#endif
