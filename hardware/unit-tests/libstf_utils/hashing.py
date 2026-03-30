MASK32 = 0xFFFF_FFFF
MASK64 = 0xFFFF_FFFF_FFFF_FFFF

def murmur32(key: int) -> int:
    key &= MASK32
    key ^= key >> 16
    key = (key * 0x85EBCA6B) & MASK32
    key ^= key >> 13
    key = (key * 0xC2B2AE35) & MASK32
    key ^= key >> 16
    return key

def murmur64(key: int) -> int:
    key &= MASK64
    key ^= key >> 33
    key = (key * 0xFF51AFD7ED558CCD) & MASK64
    key ^= key >> 33
    key = (key * 0xC4CEB9FE1A85EC53) & MASK64
    key ^= key >> 33
    return key
