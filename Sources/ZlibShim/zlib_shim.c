#include "ZlibShim.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

int proxydog_inflate(const uint8_t *input, size_t input_len, uint8_t **output,
                     size_t *output_len, size_t max_output) {
    if (input == NULL || output == NULL || output_len == NULL || input_len == 0) {
        return -1;
    }

    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    // 47 = 32 + 15: auto-detect gzip or zlib headers.
    if (inflateInit2(&stream, 47) != Z_OK) {
        return -2;
    }

    size_t capacity = 64 * 1024;
    if (capacity > max_output) {
        capacity = max_output;
    }
    uint8_t *buffer = malloc(capacity);
    if (buffer == NULL) {
        inflateEnd(&stream);
        return -3;
    }

    stream.next_in = (Bytef *)input;
    stream.avail_in = (uInt)input_len;

    size_t produced = 0;
    int status = Z_OK;
    for (;;) {
        if (produced == capacity) {
            if (capacity >= max_output) {
                status = Z_BUF_ERROR;
                break;
            }
            size_t next_capacity = capacity * 2;
            if (next_capacity > max_output) {
                next_capacity = max_output;
            }
            uint8_t *grown = realloc(buffer, next_capacity);
            if (grown == NULL) {
                status = Z_MEM_ERROR;
                break;
            }
            buffer = grown;
            capacity = next_capacity;
        }

        stream.next_out = buffer + produced;
        stream.avail_out = (uInt)(capacity - produced);
        status = inflate(&stream, Z_NO_FLUSH);
        produced = capacity - stream.avail_out;

        if (status == Z_STREAM_END) {
            break;
        }
        if (status != Z_OK) {
            break;
        }
        if (stream.avail_out != 0 && stream.avail_in == 0) {
            status = Z_DATA_ERROR;
            break;
        }
    }

    inflateEnd(&stream);

    if (status != Z_STREAM_END) {
        free(buffer);
        return status;
    }

    *output = buffer;
    *output_len = produced;
    return 0;
}

void proxydog_free(void *pointer) {
    free(pointer);
}
