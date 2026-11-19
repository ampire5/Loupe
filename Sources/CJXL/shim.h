#ifndef CJXL_SHIM_H
#define CJXL_SHIM_H

// Loupe's patched libjxl (built statically by scripts/build-deps.sh): decode.h adds
// JxlDecoderLoupeVersion, JxlDecoderGetDCImage and JxlDecoderGetDCByteCount. scripts/libjxl-env.sh puts it ahead of
// Homebrew's.

#include <jxl/decode.h>
#include <jxl/thread_parallel_runner.h>

#endif
