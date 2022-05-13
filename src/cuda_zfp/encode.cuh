#ifndef CUZFP_ENCODE_CUH
#define CUZFP_ENCODE_CUH

#include "shared.h"

namespace cuZFP {

// map two's complement signed integer to negabinary unsigned integer
inline __device__
unsigned long long int int2uint(const long long int x)
{
  return ((unsigned long long)x + 0xaaaaaaaaaaaaaaaaull) ^ 0xaaaaaaaaaaaaaaaaull;
}

inline __device__
unsigned int int2uint(const int x)
{
  return ((unsigned int)x + 0xaaaaaaaau) ^ 0xaaaaaaaau;
}

// maximum number of bit planes to encode
inline __device__ 
int precision(int maxexp, int maxprec, int minexp)
{
  // ERROR: should be MAX(0, maxexp - minexp + 2 * dims + 2)
  return MIN(maxprec, MAX(0, maxexp - minexp + 8));
}

template <typename Scalar>
inline __device__
void pad_block(Scalar *p, uint n, uint s)
{
  switch (n) 
  {
    case 0:
      p[0 * s] = 0;
      /* FALLTHROUGH */
    case 1:
      p[1 * s] = p[0 * s];
      /* FALLTHROUGH */
    case 2:
      p[2 * s] = p[1 * s];
      /* FALLTHROUGH */
    case 3:
      p[3 * s] = p[0 * s];
      /* FALLTHROUGH */
    default:
      break;
  }
}

template <class Scalar>
inline __device__
int exponent(Scalar x)
{
  if (x > 0) {
    int e;
    frexp(x, &e);
    // clamp exponent in case x is denormalized
    return max(e, 1 - get_ebias<Scalar>());
  }
  return -get_ebias<Scalar>();
}

template <class Scalar, int BlockSize>
inline __device__
int max_exponent(const Scalar* p)
{
  Scalar max_val = 0;
  for (int i = 0; i < BlockSize; ++i) {
    Scalar f = fabs(p[i]);
    max_val = max(max_val, f);
  }
  return exponent<Scalar>(max_val);
}

// lifting transform of 4-vector
template <class Int, uint s>
inline __device__ 
void fwd_lift(Int* p)
{
  Int x = *p; p += s;
  Int y = *p; p += s;
  Int z = *p; p += s;
  Int w = *p; p += s;

  // non-orthogonal transform
  //        ( 4  4  4  4) (x)
  // 1/16 * ( 5  1 -1 -5) (y)
  //        (-4  4  4 -4) (z)
  //        (-2  6 -6  2) (w)
  x += w; x >>= 1; w -= x;
  z += y; z >>= 1; y -= z;
  x += z; x >>= 1; z -= x;
  w += y; w >>= 1; y -= w;
  w += y >> 1; y -= w >> 1;

  p -= s; *p = w;
  p -= s; *p = z;
  p -= s; *p = y;
  p -= s; *p = x;
}

template <typename Scalar>
inline __device__
Scalar quantize_factor(const int &exponent, Scalar);

template <>
inline __device__
float quantize_factor<float>(const int &exponent, float)
{
  return LDEXP(1.0, get_precision<float>() - 2 - exponent);
}

template <>
inline __device__
double quantize_factor<double>(const int &exponent, double)
{
  return LDEXP(1.0, get_precision<double>() - 2 - exponent);
}

template <typename Scalar, typename Int, int BlockSize>
__device__
void fwd_cast(Int *iblock, const Scalar *fblock, int emax)
{
  Scalar s = quantize_factor(emax, Scalar());
  for (int i = 0; i < BlockSize; ++i)
    iblock[i] = (Int)(s * fblock[i]);
}

template <int BlockSize>
struct transform;

template <>
struct transform<64>
{
  template <typename Int>
  __device__
  void fwd_xform(Int *p)
  {
    // transform along x
    for (uint z = 0; z < 4; z++)
      for (uint y = 0; y < 4; y++)
        fwd_lift<Int, 1>(p + 4 * y + 16 * z);
    // transform along y
    for (uint x = 0; x < 4; x++)
      for (uint z = 0; z < 4; z++)
        fwd_lift<Int, 4>(p + 16 * z + 1 * x);
    // transform along z
    for (uint y = 0; y < 4; y++)
      for (uint x = 0; x < 4; x++)
        fwd_lift<Int, 16>(p + 1 * x + 4 * y);
   }
};

template <>
struct transform<16>
{
  template <typename Int>
  __device__
  void fwd_xform(Int *p)
  {
    // transform along x
    for (uint y = 0; y < 4; y++)
     fwd_lift<Int, 1>(p + 4 * y);
    // transform along y
    for (uint x = 0; x < 4; x++)
      fwd_lift<Int, 4>(p + 1 * x);
  }
};

template <>
struct transform<4>
{
  template <typename Int>
  __device__
  void fwd_xform(Int *p)
  {
    fwd_lift<Int, 1>(p);
  }
};

template <typename Int, typename UInt, int BlockSize>
__device__
void fwd_order(UInt* ublock, const Int* iblock)
{
  const unsigned char* perm = get_perm<BlockSize>();

  for (int i = 0; i < BlockSize; ++i)
    ublock[i] = int2uint(iblock[perm[i]]);
}

template <int block_size>
struct BlockWriter {

  uint m_word_index;
  uint m_start_bit;
  uint m_current_bit;
  const int m_maxbits; 
  Word *m_stream;

  __device__
  BlockWriter(Word *stream, const int &maxbits, const uint &block_idx) :
    m_current_bit(0),
    m_maxbits(maxbits),
    m_stream(stream)
  {
    m_word_index = (block_idx * maxbits)  / (sizeof(Word) * 8); 
    m_start_bit = uint((block_idx * maxbits) % (sizeof(Word) * 8)); 
  }

  template <typename T>
  __device__
  void print_bits(T bits)
  {
    const int bit_size = sizeof(T) * 8;
    for (int i = bit_size - 1; i >= 0; --i) {
      T one = 1;
      T mask = one << i;
      int val = (bits & mask) >> i;
      printf("%d", val);
    }
    printf("\n");
  }

  __device__
  void print(int index)
  {
    print_bits(m_stream[index]);
  }

  __device__
  long long unsigned int
  write_bits(const long long unsigned int &bits, const uint &n_bits)
  {
    const uint wbits = sizeof(Word) * 8;
    uint seg_start = (m_start_bit + m_current_bit) % wbits;
    uint write_index = m_word_index + uint((m_start_bit + m_current_bit) / wbits);
    uint seg_end = seg_start + n_bits - 1;
    uint shift = seg_start; 
    // we may be asked to write less bits than exist in 'bits'
    // so we have to make sure that anything after n is zero.
    // If this does not happen, then we may write into a zfp
    // block not at the specified index
    // uint zero_shift = sizeof(Word) * 8 - n_bits;
    Word left = (bits >> n_bits) << n_bits;
    
    Word b = bits - left;
    Word add = b << shift;
    atomicAdd(&m_stream[write_index], add); 
    // n_bits straddles the word boundary
    bool straddle = seg_start < sizeof(Word) * 8 && seg_end >= sizeof(Word) * 8;
    if (straddle) {
      Word rem = b >> (sizeof(Word) * 8 - shift);
      atomicAdd(&m_stream[write_index + 1], rem); 
    }
    m_current_bit += n_bits;
    return bits >> (Word)n_bits;
  }

  __device__
  uint write_bit(const unsigned int &bit)
  {
    const uint wbits = sizeof(Word) * 8;
    uint seg_start = (m_start_bit + m_current_bit) % wbits;
    uint write_index = m_word_index + uint((m_start_bit + m_current_bit) / wbits);
    uint shift = seg_start; 
    // we may be asked to write less bits than exist in 'bits'
    // so we have to make sure that anything after n is zero.
    // If this does not happen, then we may write into a zfp
    // block not at the specified index
    // uint zero_shift = sizeof(Word) * 8 - n_bits;
    
    Word add = (Word)bit << shift;
    atomicAdd(&m_stream[write_index], add); 
    m_current_bit += 1;

    return bit;
  }
};

template <typename Int, int BlockSize> 
inline __device__
void encode_block(BlockWriter<BlockSize> &stream, int maxbits, int maxprec, Int *iblock)
{
  transform<BlockSize> tform;
  tform.fwd_xform(iblock);

  typedef typename zfp_traits<Int>::UInt UInt;
  UInt ublock[BlockSize]; 
  fwd_order<Int, UInt, BlockSize>(ublock, iblock);

  const uint intprec = CHAR_BIT * (uint)sizeof(UInt);
  const uint kmin = intprec > maxprec ? intprec - maxprec : 0;
  uint bits = maxbits;

  for (uint k = intprec, n = 0; bits && k-- > kmin;) {
    // step 1: extract bit plane #k to x
    uint64 x = 0;
    for (uint i = 0; i < BlockSize; i++)
      x += (uint64)((ublock[i] >> k) & 1u) << i;
    // step 2: encode first n bits of bit plane
    uint m = min(n, bits);
    bits -= m;
    x = stream.write_bits(x, m);
    // step 3: unary run-length encode remainder of bit plane
    for (; n < BlockSize && bits && (bits--, stream.write_bit(!!x)); x >>= 1, n++)
      for (; n < BlockSize - 1 && bits && (bits--, !stream.write_bit(x & 1u)); x >>= 1, n++)
        ;
  }
}

template <typename Scalar, int BlockSize>
inline __device__
void zfp_encode_block(Scalar *fblock, const int maxbits, const uint block_idx, Word *stream)
{
  BlockWriter<BlockSize> block_writer(stream, maxbits, block_idx);
  int emax = max_exponent<Scalar, BlockSize>(fblock);
  int maxprec = precision(emax, get_precision<Scalar>(), get_min_exp<Scalar>());
  uint e = maxprec ? emax + get_ebias<Scalar>() : 0;
  if (e) {
    const uint ebits = get_ebits<Scalar>()+1;
    block_writer.write_bits(2 * e + 1, ebits);
    typedef typename zfp_traits<Scalar>::Int Int;
    Int iblock[BlockSize];
    fwd_cast<Scalar, Int, BlockSize>(iblock, fblock, emax);
    encode_block<Int, BlockSize>(block_writer, maxbits - ebits, maxprec, iblock);
  }
}

template <>
inline __device__
void zfp_encode_block<int, 64>(int *fblock, const int maxbits, const uint block_idx, Word *stream)
{
  BlockWriter<64> block_writer(stream, maxbits, block_idx);
  const int intprec = get_precision<int>();
  encode_block<int, 64>(block_writer, maxbits, intprec, fblock);
}

template <>
inline __device__
void zfp_encode_block<long long int, 64>(long long int *fblock, const int maxbits, const uint block_idx, Word *stream)
{
  BlockWriter<64> block_writer(stream, maxbits, block_idx);
  const int intprec = get_precision<long long int>();
  encode_block<long long int, 64>(block_writer, maxbits, intprec, fblock);
}

template <>
inline __device__
void zfp_encode_block<int, 16>(int *fblock, const int maxbits, const uint block_idx, Word *stream)
{
  BlockWriter<16> block_writer(stream, maxbits, block_idx);
  const int intprec = get_precision<int>();
  encode_block<int, 16>(block_writer, maxbits, intprec, fblock);
}

template <>
inline __device__
void zfp_encode_block<long long int, 16>(long long int *fblock, const int maxbits, const uint block_idx, Word *stream)
{
  BlockWriter<16> block_writer(stream, maxbits, block_idx);
  const int intprec = get_precision<long long int>();
  encode_block<long long int, 16>(block_writer, maxbits, intprec, fblock);
}

template <>
inline __device__
void zfp_encode_block<int, 4>(int *fblock, const int maxbits, const uint block_idx, Word *stream)
{
  BlockWriter<4> block_writer(stream, maxbits, block_idx);
  const int intprec = get_precision<int>();
  encode_block<int, 4>(block_writer, maxbits, intprec, fblock);
}

template <>
inline __device__
void zfp_encode_block<long long int, 4>(long long int *fblock, const int maxbits, const uint block_idx, Word *stream)
{
  BlockWriter<4> block_writer(stream, maxbits, block_idx);
  const int intprec = get_precision<long long int>();
  encode_block<long long int, 4>(block_writer, maxbits, intprec, fblock);
}

} // namespace cuZFP

#endif
