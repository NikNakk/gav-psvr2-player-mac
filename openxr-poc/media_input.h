#pragma once

#include <string>

struct GAVResolvedMediaInput {
    std::string path;
    bool youtubeEAC{false};
};

GAVResolvedMediaInput gav_resolve_media_input(const char *input);
