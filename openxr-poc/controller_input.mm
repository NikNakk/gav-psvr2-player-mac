#import <Foundation/Foundation.h>
#import <GameController/GameController.h>

#include "controller_input.h"

#include <atomic>
#include <cstdio>

struct GAVControllerInput {
    std::atomic<int> togglePlay{0};
    std::atomic<int> seekSteps{0};
    std::atomic<int> volumeSteps{0};
    std::atomic<int> recenter{0};
    std::atomic<float> rightX{0.0f};
    std::atomic<float> rightY{0.0f};
    dispatch_queue_t eventQueue{nullptr};
    __strong id connectObserver{nil};
    __strong id disconnectObserver{nil};
};

static void
bindPress(GCControllerButtonInput *button, std::atomic<int> *counter, int delta)
{
    if (!button) {
        return;
    }
    button.pressedChangedHandler = ^(GCControllerButtonInput *, float, BOOL pressed) {
        if (pressed) {
            counter->fetch_add(delta, std::memory_order_relaxed);
        }
    };
}

static void
bindController(GAVControllerInput *input, GCController *controller)
{
    if (!input || !controller || !controller.extendedGamepad) {
        return;
    }

    controller.handlerQueue = input->eventQueue;
    GCExtendedGamepad *pad = controller.extendedGamepad;

    // Adapted from youtube-vr-support/controller.swift. Overlay-specific
    // actions are intentionally omitted in this CLI/OpenXR POC.
    bindPress(pad.buttonA, &input->togglePlay, 1);
    bindPress(pad.buttonMenu, &input->togglePlay, 1);
    bindPress(pad.buttonY, &input->recenter, 1);
    bindPress(pad.leftShoulder, &input->seekSteps, -1);
    bindPress(pad.rightShoulder, &input->seekSteps, 1);
    bindPress(pad.dpad.left, &input->seekSteps, -1);
    bindPress(pad.dpad.right, &input->seekSteps, 1);
    bindPress(pad.dpad.up, &input->volumeSteps, 1);
    bindPress(pad.dpad.down, &input->volumeSteps, -1);

    pad.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad *, float x, float y) {
        input->rightX.store(x, std::memory_order_relaxed);
        input->rightY.store(y, std::memory_order_relaxed);
    };

    NSString *name = controller.vendorName ?: controller.productCategory ?: @"controller";
    std::printf("[controller] connected: %s\n", name.UTF8String);
}

GAVControllerInput *
gav_controller_create(void)
{
    GAVControllerInput *input = new GAVControllerInput();
    input->eventQueue = dispatch_queue_create("local.gav.monado.controller-input", DISPATCH_QUEUE_SERIAL);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    input->connectObserver = [center addObserverForName:GCControllerDidConnectNotification
                                                object:nil
                                                 queue:nil
                                            usingBlock:^(NSNotification *note) {
        GCController *controller = (GCController *)note.object;
        bindController(input, controller);
    }];
    input->disconnectObserver = [center addObserverForName:GCControllerDidDisconnectNotification
                                                   object:nil
                                                    queue:nil
                                               usingBlock:^(NSNotification *note) {
        GCController *controller = (GCController *)note.object;
        NSString *name = controller.vendorName ?: controller.productCategory ?: @"controller";
        std::printf("[controller] disconnected: %s\n", name.UTF8String);
        input->rightX.store(0.0f, std::memory_order_relaxed);
        input->rightY.store(0.0f, std::memory_order_relaxed);
    }];

    for (GCController *controller in [GCController controllers]) {
        if (controller.extendedGamepad) {
            bindController(input, controller);
        }
    }

    std::printf("[controller] controls: Cross/A or Menu play/pause; L1/R1 or D-pad left/right seek 15s; "
                "D-pad up/down volume; Triangle/Y recenter; right stick scene tilt.\n");
    return input;
}

void
gav_controller_destroy(GAVControllerInput *input)
{
    if (!input) {
        return;
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (input->connectObserver) {
        [center removeObserver:input->connectObserver];
    }
    if (input->disconnectObserver) {
        [center removeObserver:input->disconnectObserver];
    }
    delete input;
}

void
gav_controller_poll(GAVControllerInput *input, GAVControllerSnapshot *snapshot)
{
    if (!snapshot) {
        return;
    }
    *snapshot = {};
    if (!input) {
        return;
    }

    snapshot->togglePlay = input->togglePlay.exchange(0, std::memory_order_relaxed);
    snapshot->seekSteps = input->seekSteps.exchange(0, std::memory_order_relaxed);
    snapshot->volumeSteps = input->volumeSteps.exchange(0, std::memory_order_relaxed);
    snapshot->recenter = input->recenter.exchange(0, std::memory_order_relaxed);
    snapshot->rightX = input->rightX.load(std::memory_order_relaxed);
    snapshot->rightY = input->rightY.load(std::memory_order_relaxed);
}
