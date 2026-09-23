#ifndef LEADER_TIFF_H
#define LEADER_TIFF_H
#include <stdint.h>
void lt_fill_v210(const float *rgba, void *destination, uint32_t width, uint32_t height, uint32_t row_bytes);
int lt_write_tiff(const char *path, const float *rgba, uint32_t width,
                  uint32_t height, int bits, int video_range, int compressed,
                  const void *icc, uint32_t icc_size, const char *description);
int lt_check_tiff(const char *path, uint32_t *width, uint32_t *height,
                  uint16_t *bits, uint16_t *minimum, uint16_t *maximum,
                  uint32_t *unique_codes);
#endif
