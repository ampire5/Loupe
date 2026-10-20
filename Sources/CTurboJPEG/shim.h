#ifndef CTURBOJPEG_SHIM_H
#define CTURBOJPEG_SHIM_H

#include <turbojpeg.h>

// tj3Init is a function-like macro (it injects the header's version number) and tj3Set takes
// plain ints while the parameter names are enum constants, so Swift gets these thin wrappers.
static inline tjhandle ltj_init_decompress(void) { return tj3Init(TJINIT_DECOMPRESS); }
static inline int ltj_set_fast_dct(tjhandle h, int on) { return tj3Set(h, TJPARAM_FASTDCT, on); }
static inline int ltj_set_stop_on_warning(tjhandle h, int on) { return tj3Set(h, TJPARAM_STOPONWARNING, on); }
/// Which extra markers the header parse keeps: 4 = ICC profile only (needed by `tj3GetICCProfile`;
/// 2, the default, would copy every APP/COM marker).
static inline int ltj_set_save_icc(tjhandle h) { return tj3Set(h, TJPARAM_SAVEMARKERS, 4); }
static inline int ltj_set_scaling(tjhandle h, int num, int denom) {
    tjscalingfactor factor = { num, denom };
    return tj3SetScalingFactor(h, factor);
}
static inline int ltj_get_colorspace(tjhandle h) { return tj3Get(h, TJPARAM_COLORSPACE); }
static inline int ltj_get_progressive(tjhandle h) { return tj3Get(h, TJPARAM_PROGRESSIVE); }
static inline int ltj_get_width(tjhandle h) { return tj3Get(h, TJPARAM_JPEGWIDTH); }
static inline int ltj_get_height(tjhandle h) { return tj3Get(h, TJPARAM_JPEGHEIGHT); }
static inline int ltj_get_subsamp(tjhandle h) { return tj3Get(h, TJPARAM_SUBSAMP); }
static inline int ltj_pixel_format_bgra(void) { return TJPF_BGRA; }

/// Width of one iMCU in pixels for a `TJPARAM_SUBSAMP` value (tjMCUWidth is a static array),
/// or 0 when `subsamp` is out of range (TJSAMP_UNKNOWN is -1 for unusual chroma sampling).
static inline int ltj_mcu_width(int subsamp) {
    return subsamp >= 0 && subsamp < TJ_NUMSAMP ? tjMCUWidth[subsamp] : 0;
}

/// `dimension` scaled by `factor`, rounded up exactly as the decompressor does (TJSCALED).
static inline int ltj_scaled(int dimension, tjscalingfactor factor) { return TJSCALED(dimension, factor); }

#endif
