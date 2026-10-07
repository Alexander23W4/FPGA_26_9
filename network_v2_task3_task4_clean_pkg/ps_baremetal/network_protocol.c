#include "network_protocol.h"

u16 net_crc16(const u8 *data, u32 length)
{
    u16 crc = 0xFFFFU;
    u32 i;
    u32 bit;
    for (i = 0U; i < length; ++i) {
        crc ^= (u16)data[i] << 8;
        for (bit = 0U; bit < 8U; ++bit) {
            if ((crc & 0x8000U) != 0U) {
                crc = (u16)((crc << 1) ^ 0x1021U);
            } else {
                crc = (u16)(crc << 1);
            }
        }
    }
    return crc;
}

u32 net_pack_header(u8 *buffer, u8 command, u16 sequence, u16 payload_length)
{
    buffer[0] = NET_MAGIC_0;
    buffer[1] = NET_MAGIC_1;
    buffer[2] = NET_VERSION;
    buffer[3] = command;
    buffer[4] = (u8)(sequence & 0xFFU);
    buffer[5] = (u8)((sequence >> 8U) & 0xFFU);
    buffer[6] = (u8)(payload_length & 0xFFU);
    buffer[7] = (u8)((payload_length >> 8U) & 0xFFU);
    return 8U;
}
