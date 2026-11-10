#ifndef ZLIB_SHIM_H
#define ZLIB_SHIM_H

#include <stddef.h>
#include <stdint.h>

/// Inflates gzip or zlib (deflate) data in one shot.
///
/// - Parameters:
///   - input: compressed bytes.
///   - input_len: number of compressed bytes.
///   - output: receives a malloc'd buffer (caller frees with proxydog_free).
///   - output_len: receives the decoded size.
///   - max_output: refuse to produce more than this many bytes.
/// - Returns: 0 on success, non-zero on failure (zlib error code).
int proxydog_inflate(const uint8_t *input, size_t input_len, uint8_t **output,
                     size_t *output_len, size_t max_output);

/// Frees a buffer returned by proxydog_inflate.
void proxydog_free(void *pointer);

#endif /* ZLIB_SHIM_H */
