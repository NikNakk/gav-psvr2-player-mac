#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GAVControllerInput GAVControllerInput;

typedef struct GAVControllerSnapshot {
    int togglePlay;
    int seekSteps;
    int volumeSteps;
    int recenter;
    int uiToggle;
    int uiSelect;
    int uiBack;
    int uiNavX;
    int uiNavY;
    float rightX;
    float rightY;
} GAVControllerSnapshot;

GAVControllerInput *gav_controller_create(void);
void gav_controller_destroy(GAVControllerInput *input);
void gav_controller_poll(GAVControllerInput *input, GAVControllerSnapshot *snapshot);

#ifdef __cplusplus
}
#endif
