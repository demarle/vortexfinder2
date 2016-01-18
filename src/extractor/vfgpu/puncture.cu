#include "vfgpu.h"
#include "threadIdx.cuh"
#include <algorithm>
#include <curand.h>
#include <cstdio>

static gpu_hdr_t h[2];
static gpu_hdr_t *d_h[2] = {NULL};
static float *d_rho[2] = {NULL}, 
             *d_phi[2] = {NULL}, 
             *d_re[2] = {NULL}, 
             *d_im[2] = {NULL};
static float *d_pert = NULL;

static curandGenerator_t gen;

static unsigned int *d_pfcount=NULL;
static gpu_pf_t *d_pfbuf=NULL;
static unsigned int pfcount=0;
static gpu_pf_t *pfbuf=NULL;

static unsigned int *d_pecount=NULL;
static gpu_pe_t *d_pebuf=NULL;
static unsigned int pecount=0;
static gpu_pe_t *pebuf=NULL;

static float *d_density = NULL;
static float *density = NULL;

inline void checkCuda(cudaError_t e, const char *situation) {
  if (e != cudaSuccess) {
    printf("CUDA Error: %s: %s\n", situation, cudaGetErrorString(e));
  }
}

inline void checkLastCudaError(const char *situation) {
  checkCuda(cudaGetLastError(), situation);
}

static inline int idivup(int a, int b)
{
  return (a%b!=0) ? (a/b+1) : (a/b); 
}

static inline dim3 idivup(dim3 a, dim3 b)
{
  return dim3(idivup(a.x, b.x), idivup(a.y, b.y), idivup(a.z, b.z));
}

template <typename T>
__device__
inline bool find_zero_barycentric(const T re[3], const T im[3], T lambda[3], T epsilon=0)
{
  T D = re[0]*im[1] + re[1]*im[2] + re[2]*im[0] - re[2]*im[1] - re[1]*im[0] - re[0]*im[2]; // TODO: check if D=0?
  T det[3] = {
    re[1]*im[2] - re[2]*im[1], 
    re[2]*im[0] - re[0]*im[2], 
    re[0]*im[1] - re[1]*im[0]
  };

  lambda[0] = det[0]/D; 
  lambda[1] = det[1]/D; 
  lambda[2] = det[2]/D;

  // if (lambda[0]>=0 && lambda[1]>=0 && lambda[2]>=0) return true; 
  if (lambda[0]>=-epsilon && lambda[1]>=-epsilon && lambda[2]>=-epsilon) return true; 
  else return false; 
}

template <typename T>
__device__
inline bool find_zero_triangle(const T re[3], const T im[3], const T X[3][3], T pos[3], T epsilon=0)
{
  T lambda[3]; 
  bool succ = find_zero_barycentric(re, im, lambda, epsilon);

  T R[3][2] = {{X[0][0]-X[2][0], X[1][0]-X[2][0]}, 
               {X[0][1]-X[2][1], X[1][1]-X[2][1]}, 
               {X[0][2]-X[2][2], X[1][2]-X[2][2]}}; 

  pos[0] = R[0][0]*lambda[0] + R[0][1]*lambda[1] + X[2][0]; 
  pos[1] = R[1][0]*lambda[0] + R[1][1]*lambda[1] + X[2][1]; 
  pos[2] = R[2][0]*lambda[0] + R[2][1]*lambda[1] + X[2][2]; 

  return succ; 
}

// find the zero point in [0, 1]x[0, 1] quad, using generalized eigenvalue problem
template <typename T>
__device__
static inline bool find_zero_unit_quad_bilinear(const T re[4], const T im[4], T pos[2], T epsilon=0)
{
  T f00 = re[0], f10 = re[1], f01 = re[3], f11 = re[2], // counter-clockwise
    g00 = im[0], g10 = im[1], g01 = im[3], g11 = im[2];
  T A0 = f00 - f10 - f01 + f11, 
    B0 = f10 - f00, 
    C0 = f01 - f00, 
    D0 = f00,
    A1 = g00 - g10 - g01 + g11, 
    B1 = g10 - g00, 
    C1 = g01 - g00, 
    D1 = g00; 
  T M0[4] = {-B0, -D0, -B1, -D1}; // stored in row major
  // T M1[4] = {A0, C0, A1, C1}; // (yM1 - M0)v = 0, v = {x, 1}^T

  T detM1 = A0*C1 - A1*C0; // TODO: check if detM1==0
  T invM1[4] = {C1/detM1, -C0/detM1, -A1/detM1, A0/detM1};

  // Q = invM1*M0
  T Q[4] = {
    invM1[0]*M0[0] + invM1[1]*M0[2], 
    invM1[0]*M0[1] + invM1[1]*M0[3], 
    invM1[2]*M0[0] + invM1[3]*M0[2], 
    invM1[2]*M0[1] + invM1[3]*M0[3]
  };

  // compute y=eig(Q)
  T trace = Q[0] + Q[3];
  T det = Q[0]*Q[3] - Q[1]*Q[2];
  T lambda[2] = {
    trace/2 + sqrt(trace*trace/4 - det), 
    trace/2 - sqrt(trace*trace/4 - det)
  }; 

  T x[2] = {
    (lambda[0]-Q[3])/Q[2], 
    (lambda[1]-Q[3])/Q[2]
  }; 
  T y[2] = {
    lambda[0], 
    lambda[1]
  };

  bool found = false; 
  for (int i=0; i<2; i++) // check the two roots 
    if (x[i]>=0 && x[i]<=1 && y[i]>=0 && y[i]<=1) {
      pos[0] = x[i]; 
      pos[1] = y[i];
      found = true; 
      break; 
    }
  
  if (!found) // check again, loosing creteria
    for (int i=0; i<2; i++)  
      if (x[i]>=-epsilon && x[i]<=1+epsilon && y[i]>=-epsilon && y[i]<=1+epsilon) {
        pos[0] = x[i]; 
        pos[1] = y[i];
        found = true; 
        break; 
      }

  return found; 
}

template <typename T>
__device__
static inline bool find_zero_quad_bilinear(const T re[4], const T im[4], const T X[4][3], T pos[3], T epsilon=0)
{
  T p[2]; 

  bool succ = find_zero_unit_quad_bilinear(re, im, p, epsilon); 
  if (!succ) return false;

  T u[3], v[3]; 

  u[0] = (1-p[0])*X[0][0] + p[0]*X[1][0];
  u[1] = (1-p[0])*X[0][1] + p[0]*X[1][1];
  u[2] = (1-p[0])*X[0][2] + p[0]*X[1][2];

  v[0] = (1-p[0])*X[3][0] + p[0]*X[2][0];
  v[1] = (1-p[0])*X[3][1] + p[0]*X[2][1];
  v[2] = (1-p[0])*X[3][2] + p[0]*X[2][2];

  pos[0] = (1-p[1])*u[0] + p[1]*v[0];
  pos[1] = (1-p[1])*u[1] + p[1]*v[1];
  pos[2] = (1-p[1])*u[2] + p[1]*v[2];

  return true; 
}

template <typename T>
__device__
static inline bool find_tri_center(const T X[3][3], T pos[3])
{
  pos[0] = (X[0][0] + X[1][0] + X[2][0]) / 3;
  pos[1] = (X[0][1] + X[1][1] + X[2][0]) / 3;
  pos[2] = (X[0][2] + X[1][2] + X[2][0]) / 3;

  return true;
}

template <typename T>
__device__
static inline bool find_quad_center(const T X[4][3], T pos[3])
{
  pos[0] = 0.25*(X[0][0] + X[1][0] + X[2][0] + X[3][0]);
  pos[1] = 0.25*(X[0][1] + X[1][1] + X[2][0] + X[3][1]);
  pos[2] = 0.25*(X[0][2] + X[1][2] + X[2][0] + X[3][2]);

  return true;
}

template <typename T, int meshtype>
__device__
static inline bool find_zero(const T re[], const T im[], const T X[][3], T pos[3], T epsilon=T(0))
{
  if (meshtype == GLGPU3D_MESH_TET) 
    return find_zero_triangle(re, im, X, pos, epsilon);
    // return find_tri_center(X, pos);
  else if (meshtype == GLGPU3D_MESH_HEX)
    return find_zero_quad_bilinear(re, im, X, pos, epsilon);
    // return find_quad_center(X, pos);
  else
    return false;
}

template <typename T>
__device__
inline static T fmod1(T x, T y)
{
  T z = fmod(x, y);
  if (z<0) z += y;
  return z;
}

template <typename T>
__device__
inline static T mod2pi(T x)
{
  T y = fmod(x, 2*M_PI); 
  if (y<0) y+= 2*M_PI;
  return y; 
}

template <typename T>
__device__
inline static T mod2pi1(T x)
{
  return mod2pi(x + M_PI) - M_PI;
}

template <typename T> 
__device__
inline int sgn(T x) 
{
  return (T(0) < x) - (x < T(0));
}

template <typename T>
__device__
static inline T inner_product(const T A[3], const T B[3])
{
  return A[0]*B[0] + A[1]*B[1] + A[2]*B[2];
}

template <typename T> 
__device__
T line_integral(const gpu_hdr_t& h, const T X0[], const T X1[], const T A0[], const T A1[]) 
{
  T dX[3] = {X1[0] - X0[0], X1[1] - X0[1], X1[2] - X0[2]};
  T A[3] = {A0[0] + A1[0], A0[1] + A1[1], A0[2] + A1[2]};

  for (int i=0; i<3; i++)
    if (dX[i] > h.lengths[i]/2) dX[i] -= h.lengths[i];
    else if (dX[i] < -h.lengths[i]/2) dX[i] += h.lengths[i];

  return 0.5 * inner_product(A, dX);
}

__device__
inline void nid2nidx(const gpu_hdr_t& h, int id, int idx[3])
{
  const int s = h.d[0] * h.d[1]; 
  const int k = id / s; 
  const int j = (id - k*s) / h.d[0]; 
  const int i = id - k*s - j*h.d[0]; 

  idx[0] = i; idx[1] = j; idx[2] = k;
}

__device__
inline int nidx2nid(const gpu_hdr_t& h, const int idx_[3])
{
  int idx[3] = {idx_[0], idx_[1], idx_[2]};
  for (int i=0; i<3; i++) {
    idx[i] = idx[i] % h.d[i];
    if (idx[i] < 0)
      idx[i] += h.d[i];
  }
  return idx[0] + h.d[0] * (idx[1] + h.d[1] * idx[2]); 
}

__device__
inline bool valid_nidx(const gpu_hdr_t& h, const int idx[3])
{
  bool v[3] = {
    idx[0]>=0 && idx[0]<h.d[0],
    idx[1]>=0 && idx[1]<h.d[1],
    idx[2]>=0 && idx[2]<h.d[2]
  };
  return v[0] && v[1] && v[2];
}

__device__
inline void fid2fidx_tet(const gpu_hdr_t& h, int id, int idx[4])
{
  int nid = id / 12;
  nid2nidx(h, nid, idx);
  idx[3] = id % 12;
}

__device__
inline void fid2fidx_hex(const gpu_hdr_t& h, unsigned int id, int idx[4])
{
  unsigned int nid = id / 3;
  nid2nidx(h, nid, idx);
  idx[3] = id % 3;
}

__device__
bool valid_fidx_tet(const gpu_hdr_t& h,const int fidx[4])
{
  if (fidx[3]<0 || fidx[3]>=12) return false;
  else {
    int o[3] = {0};
    for (int i=0; i<3; i++)
      if (h.pbc[i]) {
        if (fidx[i] < 0 || fidx[i] >= h.d[i]) return false;
      } else {
        if (fidx[i] < 0 || fidx[i] > h.d[i]-1) return false;
        else if (fidx[i] == h.d[i]-1) o[i] = 1;
      }
    
    const int sum = o[0] + o[1] + o[2];
    if (sum == 0) return true;
    else if (o[0] + o[1] + o[2] > 1) return false;
    else if (o[0] && (fidx[3] == 4 || fidx[3] == 5)) return true;
    else if (o[1] && (fidx[3] == 2 || fidx[3] == 3)) return true; 
    else if (o[2] && (fidx[3] == 0 || fidx[3] == 1)) return true;
    else return false;
  }
}

__device__
bool valid_fidx_hex(const gpu_hdr_t& h, const int fidx[4])
{
  if (fidx[3]<0 || fidx[3]>=3) return false;
  else {
    int o[3] = {0}; 
    for (int i=0; i<3; i++) 
      if (h.pbc[i]) {
        if (fidx[i]<0 || fidx[i]>=h.d[i]) return false;
      } else {
        if (fidx[i]<0 || fidx[i]>h.d[i]-1) return false;
        else if (fidx[i] == h.d[i]-1) o[i] = 1;
      }

    const int sum = o[0] + o[1] + o[2];
    if (sum == 0) return true;
    else if (o[0] + o[1] + o[2] > 1) return false;
    else if (o[0] && fidx[3] == 0) return true; 
    else if (o[1] && fidx[3] == 1) return true;
    else if (o[2] && fidx[3] == 2) return true;
    else return false;
  }
}

__device__
inline void eid2eidx_tet(const gpu_hdr_t& h, int id, int idx[4])
{
  int nid = id / 7;
  nid2nidx(h, nid, idx);
  idx[3] = id % 7;
}

__device__
inline void eid2eidx_hex(const gpu_hdr_t& h, int id, int idx[4]) 
{
  int nid = id / 3;
  nid2nidx(h, nid, idx);
  idx[3] = id % 3;
}

__device__
inline bool valid_eidx_tet(const gpu_hdr_t& h, const int eidx[4])
{
  if (eidx[3]<0 || eidx[3]>=7) return false;
  else {
    for (int i=0; i<3; i++)
      if (h.pbc[i]) {
        if (eidx[i] < 0 || eidx[i] >= h.d[i]) return false;
      } else {
        if (eidx[i] < 0 || eidx[i] >= h.d[i]-1) return false;
      }
    return true;
  }
}

__device__
inline bool valid_eidx_hex(const gpu_hdr_t& h, const int eidx[4])
{
  if (eidx[3]<0 || eidx[3]>=3) return false;
  else {
    for (int i=0; i<3; i++) 
      if (h.pbc[i]) {
        if (eidx[i]<0 || eidx[i]>=h.d[i]) return false;
      } else {
        if (eidx[i]<0 || eidx[i]>=h.d[i]-1) return false;
      }
    return true;
  }
}

__device__
inline bool fid2nodes_tet(const gpu_hdr_t& h, int id, int nidxs[3][3])
{
  const int nodes_idx[12][3][3] = { // 12 types of faces
    {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}}, // ABC
    {{0, 0, 0}, {1, 1, 0}, {0, 1, 0}}, // ACD
    {{0, 0, 0}, {1, 0, 0}, {1, 0, 1}}, // ABF
    {{0, 0, 0}, {0, 0, 1}, {1, 0, 1}}, // AEF
    {{0, 0, 0}, {0, 1, 0}, {0, 0, 1}}, // ADE
    {{0, 1, 0}, {0, 0, 1}, {0, 1, 1}}, // DEH
    {{0, 0, 0}, {0, 1, 0}, {1, 0, 1}}, // ADF
    {{0, 1, 0}, {1, 0, 1}, {1, 1, 1}}, // DFG
    {{0, 1, 0}, {0, 0, 1}, {1, 0, 1}}, // DEF
    {{1, 1, 0}, {0, 1, 0}, {1, 0, 1}}, // CDF
    {{0, 0, 0}, {1, 1, 0}, {1, 0, 1}}, // ACF
    {{0, 1, 0}, {0, 0, 1}, {1, 1, 1}}  // DEG
  };

  int fidx[4];
  fid2fidx_tet(h, id, fidx);

  if (valid_fidx_tet(h, fidx)) {
    const int type = fidx[3];
    for (int p=0; p<3; p++) 
      for (int q=0; q<3; q++) 
        nidxs[p][q] = fidx[q] + nodes_idx[type][p][q];
    return true;
  }
  else
    return false;
}

__device__
inline bool fid2nodes_hex(const gpu_hdr_t &h, int id, int nidxs[4][3])
{
  const int nodes_idx[3][4][3] = { // 3 types of faces
    {{0, 0, 0}, {0, 1, 0}, {0, 1, 1}, {0, 0, 1}}, // YZ
    {{0, 0, 0}, {0, 0, 1}, {1, 0, 1}, {1, 0, 0}}, // ZX
    {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}}  // XY
  };
  
  int fidx[4];
  fid2fidx_hex(h, id, fidx);

  if (valid_fidx_hex(h, fidx)) {
    const int type = fidx[3];
    for (int p=0; p<4; p++) 
      for (int q=0; q<3; q++) 
        nidxs[p][q] = fidx[q] + nodes_idx[type][p][q];
    return true;
  }
  else
    return false;
}

__device__
inline bool eid2nodes_tet(const gpu_hdr_t& h, int eid, int nidxs[2][3])
{
  const int nodes_idx[7][2][3] = { // 7 types of edges
    {{0, 0, 0}, {1, 0, 0}}, // AB
    {{0, 0, 0}, {1, 1, 0}}, // AC
    {{0, 0, 0}, {0, 1, 0}}, // AD
    {{0, 0, 0}, {0, 0, 1}}, // AE
    {{0, 0, 0}, {1, 0, 1}}, // AF
    {{0, 1, 0}, {0, 0, 1}}, // DE
    {{0, 1, 0}, {1, 0, 1}}, // DF
  };
  
  int eidx[4];
  eid2eidx_tet(h, eid, eidx);

  if (valid_eidx_tet(h, eidx)) {
    const int type = eidx[3];
    for (int p=0; p<2; p++) 
      for (int q=0; q<3; q++) 
        nidxs[p][q] = eidx[q] + nodes_idx[type][p][q];
    return true;
  }
  else
    return false;
}

__device__
inline bool eid2nodes_hex(const gpu_hdr_t& h, int eid, int nidxs[2][3])
{
  const int nodes_idx[3][2][3] = { // 3 types of edges
    {{0, 0, 0}, {1, 0, 0}}, 
    {{0, 0, 0}, {0, 1, 0}}, 
    {{0, 0, 0}, {0, 0, 1}}
  };

  int eidx[4];
  eid2eidx_hex(h, eid, eidx);

  if (valid_eidx_hex(h, eidx)) {
    const int type = eidx[3];
    for (int p=0; p<2; p++) 
      for (int q=0; q<3; q++) 
        nidxs[p][q] = eidx[q] + nodes_idx[type][p][q];
    return true;
  }
  else
    return false;
}

template <typename T>
__device__
inline void nidx2pos(const gpu_hdr_t& h, const int nidx[3], T X[3])
{
  for (int i=0; i<3; i++) 
    X[i] = nidx[i] * h.cell_lengths[i] + h.origins[i];
}

template <typename T>
__device__
inline void magnetic_potential(const gpu_hdr_t& h, T X[3], T A[3])
{
  if (h.B[1]>0) {
    A[0] = -h.Kx; 
    A[1] = X[0] * h.B[2];
    A[2] = -X[0] * h.B[1];
  } else {
    A[0] = -X[1] * h.B[2] - h.Kx;
    A[1] = 0;
    A[2] = X[1] * h.B[0];
  }
}

template <typename T, int meshtype>
__device__
inline bool get_face_values(
    const gpu_hdr_t& h, 
    int fid, 
    T X[][3],
    T A[][3],
    T rho[],
    T phi[],
    const T *rho_,
    const T *phi_)
{
  const int nnodes = meshtype == GLGPU3D_MESH_TET ? 3 : 4;
  int nidxs[nnodes][3], nids[nnodes];
  bool valid = meshtype == GLGPU3D_MESH_TET ? fid2nodes_tet(h, fid, nidxs) : fid2nodes_hex(h, fid, nidxs);
  
  if (valid) {
    for (int i=0; i<nnodes; i++) {
      nids[i] = nidx2nid(h, nidxs[i]);
      // re[i] = re_[nids[i]];
      // im[i] = im_[nids[i]];
      // rho[i] = sqrt(re[i]*re[i] + im[i]*im[i]);
      // phi[i] = atan2(im[i], re[i]);
      rho[i] = rho_[nids[i]];
      phi[i] = phi_[nids[i]];
   
      nidx2pos(h, nidxs[i], X[i]);
      magnetic_potential(h, X[i], A[i]); 
    }
  }

  return valid;
}

template <typename T, int meshtype>
__device__
inline bool get_vface_values(
    const gpu_hdr_t& h, 
    const gpu_hdr_t& h1, 
    int eid, 
    T X[4][3],
    T A[4][3],
    T phi[4],
    const T *phi_,
    const T *phi1_)
{
  int nidxs[2][3], nids[2];
  bool valid = meshtype == GLGPU3D_MESH_TET ? eid2nodes_tet(h, eid, nidxs) : eid2nodes_hex(h, eid, nidxs);

  if (valid) {
    nids[0] = nidx2nid(h, nidxs[0]);
    nids[1] = nidx2nid(h, nidxs[1]);

    phi[0] = phi_[nids[0]]; 
    phi[1] = phi_[nids[1]];
    phi[2] = phi1_[nids[1]];
    phi[3] = phi1_[nids[0]];

    nidx2pos(h, nidxs[0], X[0]);
    nidx2pos(h, nidxs[1], X[1]);
    nidx2pos(h1, nidxs[1], X[2]);
    nidx2pos(h1, nidxs[0], X[3]);

    magnetic_potential(h, X[0], A[0]);
    magnetic_potential(h, X[1], A[1]);
    magnetic_potential(h1, X[2], A[2]);
    magnetic_potential(h1, X[3], A[3]);

    return true;
  } else 
    return false;
}

template <typename T>
__device__
inline int contour_chirality(
    const gpu_hdr_t &h, 
    int nnodes, // nnodes <= 4
    const T phi[], 
    const T X[][3], 
    const T A[][3],
    T delta[])
{
  T phase_jump = 0;
  for (int i=0; i<nnodes; i++) {
    int j = (i+1) % nnodes;
    delta[i] = phi[j] - phi[i]; 
    T li = line_integral(h, X[i], X[j], A[i], A[j]), 
      qp = 0; // TODO
    delta[i] = mod2pi1(delta[i] - li + qp);
    phase_jump -= delta[i];
  }
  
  if (fabs(phase_jump)<0.5) return 0; // not punctured
  else return sgn(phase_jump);
}

// for space-time vfaces
template <typename T>
__device__
inline int contour_chirality_spt(
    const gpu_hdr_t &h, 
    const gpu_hdr_t &h1, 
    const T phi[4], 
    const T X[4][3], 
    const T A[4][3],
    T delta[])
{
  T li[4] = { // FIXME: varying B
    line_integral(h, X[0], X[1], A[0], A[1]), 
    0, 
    line_integral(h, X[1], X[0], A[2], A[3]), 
    0};
  T qp[4] = {0, 0, 0, 0}; // FIXME

  T phase_jump = 0;
  for (int i=0; i<4; i++) {
    int j = (i+1) % 4;
    delta[i] = phi[j] - phi[i]; 
    delta[i] = mod2pi1(delta[i] - li[i] + qp[i]);
    phase_jump -= delta[i];
  }
  
  if (fabs(phase_jump)<0.5) return 0; // not punctured
  else return sgn(phase_jump);
}

template <typename T>
__device__
inline void gauge_transform(
    int nnodes, 
    const T rho[],
    const T delta[],
    T phi[], 
    T re[], 
    T im[])
{
  re[0] = rho[0] * cos(phi[0]);
  im[0] = rho[0] * sin(phi[0]);
  for (int i=1; i<nnodes; i++) {
    phi[i] = phi[i-1] + delta[i-1];
    re[i] = rho[i] * cos(phi[i]);
    im[i] = rho[i] * sin(phi[i]);
  }
}

template <typename T, int meshtype>
__device__
inline int extract_face(
    const gpu_hdr_t& h, 
    int fid,
    unsigned int *pfcount,
    gpu_pf_t *pfbuf, 
    const T *rho_, 
    const T *phi_)
{
  const int nnodes = meshtype == GLGPU3D_MESH_TET ? 3 : 4;
  T X[nnodes][3], A[nnodes][3], rho[nnodes], phi[nnodes], re[nnodes], im[nnodes];
  T delta[nnodes];
  
  bool valid = get_face_values<T, meshtype>(h, fid, X, A, rho, phi, rho_, phi_);
  if (!valid) return 0;

  // compute phase shift
  int chirality = contour_chirality(h, nnodes, phi, X, A, delta);
  if (chirality == 0) return 0;
  
  // gauge transformation
  gauge_transform(nnodes, rho, delta, phi, re, im);

  // find puncture point
  gpu_pf_t pf; 
  pf.fid = fid;
  pf.chirality = chirality;
  find_zero<T, meshtype>(re, im, X, pf.pos, T(1));
  
  unsigned int idx = atomicInc(pfcount, 0xffffffff);
  pfbuf[idx] = pf;

  return chirality;
}

template <typename T, int meshtype>
__device__
inline int extract_edge(
    const gpu_hdr_t& h, 
    const gpu_hdr_t& h1, 
    int eid,
    unsigned int *pecount,
    gpu_pe_t *pebuf, 
    const T *phi_,
    const T *phi1_)
{
  const int nnodes = 4;
  T X[nnodes][3], A[nnodes][3], phi[nnodes];
  T delta[nnodes];
  
  bool valid = get_vface_values<T, meshtype>(h, h1, eid, X, A, phi, phi_, phi1_);
  if (!valid) return 0;

  // compute phase shift
  int chirality = contour_chirality_spt(h, h1, phi, X, A, delta);
  if (chirality == 0) return 0;
  
  unsigned int idx = atomicInc(pecount, 0xffffffff);
  pebuf[idx].eid = eid;
  pebuf[idx].chirality = chirality;

  return chirality;
}

template <typename T, bool pertubation>
__global__
static void compute_rho_phi_kernel(
    const gpu_hdr_t *h, 
    T *rho, 
    T *phi,
    const T *re,
    const T *im,
    const T *pert=NULL)
{
  int idx = getGlobalIdx_3D_1D();
  if (idx>h->d[0]*h->d[1]*h->d[2]) return;

  T r, i;

  if (pertubation) {
    r = re[idx] + pert[idx*2];
    i = im[idx] + pert[idx*2+1];
  } else {
    r = re[idx];
    i = im[idx];
  }

  rho[idx] = sqrt(r*r + i*i);
  phi[idx] = atan2(i, r);
}

template <typename T, int meshtype>
__global__
static void extract_faces_kernel(
    const gpu_hdr_t* h, 
    unsigned int *pfcount,
    gpu_pf_t *pfbuf,
    const T *rho, 
    const T *phi)
{
  const int nfacetypes = meshtype == GLGPU3D_MESH_TET ? 12 : 3;
  int fid = getGlobalIdx_3D_1D();
  if (fid>h->d[0]*h->d[1]*h->d[2]*nfacetypes) return;

#if 0 // use global memory
  extract_face<T, meshtype>(*h, fid, pfcount, pfbuf, rho, phi);
#else // use shared memory
  extern __shared__ char smem[];
  unsigned int *spfcount = (unsigned int*)smem;
  gpu_pf_t *spfbuf= (gpu_pf_t*)(smem + sizeof(int));
 
  if (threadIdx.x == 0)
    *spfcount = 0;
  __syncthreads();
  
  extract_face<T, meshtype>(*h, fid, spfcount, spfbuf, rho, phi);
  __syncthreads();

  if (threadIdx.x == 0 && (*spfcount)>0) {
    unsigned int idx = atomicAdd(pfcount, *spfcount);
    // printf("idx=%d, count=%d\n", idx, *spfcount);
    memcpy(pfbuf + idx, spfbuf, (*spfcount) * sizeof(gpu_pf_t));
  }
#endif
}

template <typename T, int meshtype>
__global__
static void extract_edges_kernel(
    const gpu_hdr_t* h, 
    const gpu_hdr_t* h1, 
    unsigned int *pecount,
    gpu_pe_t *pebuf,
    const T *phi, 
    const T *phi1)
{
  const int nedgetypes = meshtype == GLGPU3D_MESH_TET ? 7 : 3;
  const int eid = getGlobalIdx_3D_1D();
  if (eid>h->d[0]*h->d[1]*h->d[2]*nedgetypes) return;

#if 0 // use global memory
  extract_edge<T, meshtype>(*h, *h1, eid, pecount, pebuf, phi, phi1);
#else // use shared memory
  extern __shared__ char smem[];
  unsigned int *specount = (unsigned int*)smem;
  gpu_pe_t *spebuf = (gpu_pe_t*)(smem + sizeof(int));
 
  if (threadIdx.x == 0)
    *specount = 0;
  __syncthreads();
  
  extract_edge<T, meshtype>(*h, *h1, eid, specount, spebuf, phi, phi1);
  __syncthreads();

  if (threadIdx.x == 0 && (*specount)>0) {
    unsigned int idx = atomicAdd(pecount, *specount);
    // printf("idx=%d, count=%d\n", idx, *specount);
    memcpy(pebuf + idx, spebuf, (*specount) * sizeof(gpu_pe_t));
  }
#endif
}

void vfgpu_destroy_data()
{
  for (int slot=0; slot<2; slot++) {
    cudaFree(d_h[slot]);
    cudaFree(d_rho[slot]);
    cudaFree(d_phi[slot]);
    cudaFree(d_re[slot]);
    cudaFree(d_im[slot]);

    d_rho[slot] = d_phi[slot] = d_re[slot] = d_im[slot] = NULL; 
    d_h[slot] = NULL;
  }

  cudaFree(d_pfbuf);
  d_pfbuf = NULL;
  free(pfbuf);
  pfbuf = NULL;

  cudaFree(d_pebuf);
  d_pebuf = NULL;
  free(pebuf);
  pebuf = NULL;
 
  if (d_pert != NULL) {
    cudaFree(d_pert);
    d_pert = NULL;
    curandDestroyGenerator(gen);
  }

  if (d_density != NULL) 
    cudaFree(d_density);
  if (density != NULL)
    free(density);
  
  checkLastCudaError("destroying data");
}

void vfgpu_initialize(
    bool enable_pertubation)
{

}

void vfgpu_rotate_timesteps()
{
  std::swap(d_h[0], d_h[1]);
  std::swap(d_rho[0], d_rho[1]);
  std::swap(d_phi[0], d_phi[1]);
  std::swap(d_re[0], d_re[1]);
  std::swap(d_im[0], d_im[1]);
}

void vfgpu_upload_data(
    int slot, 
    const gpu_hdr_t& h, 
    const float *re, 
    const float *im)
{
  const int count = h.count;
  const int max_pf_count = count*12*0.1, 
            max_pe_count = count*7*0.1;
 
  memcpy(&::h[slot], &h, sizeof(gpu_hdr_t));
  
  if (d_rho[slot] == NULL) { // FIXME
    cudaMalloc((void**)&d_h[slot], sizeof(gpu_hdr_t));
    cudaMalloc((void**)&d_re[slot], sizeof(float)*count);
    cudaMalloc((void**)&d_im[slot], sizeof(float)*count);
    cudaMalloc((void**)&d_rho[slot], sizeof(float)*count);
    cudaMalloc((void**)&d_phi[slot], sizeof(float)*count);
  }

  if (pfbuf == NULL) {
    pfbuf = (gpu_pf_t*)malloc(max_pf_count*sizeof(gpu_pf_t));
    cudaMalloc((void**)&d_pfcount, sizeof(unsigned int));
    cudaMalloc((void**)&d_pfbuf, sizeof(gpu_pf_t)*max_pf_count);
  }

  if (pebuf == NULL) {
    pebuf = (gpu_pe_t*)malloc(max_pe_count*sizeof(gpu_pe_t));
    cudaMalloc((void**)&d_pecount, sizeof(unsigned int));
    cudaMalloc((void**)&d_pebuf, sizeof(gpu_pe_t)*max_pe_count);
  }
    
  cudaMemcpy(d_h[slot], &h, sizeof(gpu_hdr_t), cudaMemcpyHostToDevice);
  cudaMemcpy(d_re[slot], re, sizeof(float)*count, cudaMemcpyHostToDevice);
  cudaMemcpy(d_im[slot], im, sizeof(float)*count, cudaMemcpyHostToDevice);
 
  checkLastCudaError("copy data to device");
}

void vfgpu_compute_rho_phi(int slot, float pertubation=0.f)
{
  const int count = h[slot].count;
  const int maxGridDim = 1024; // 32768;
  const int blockSize = 256;
  const int nBlocks = idivup(count, blockSize);
  dim3 gridSize; 
  if (nBlocks >= maxGridDim) 
    gridSize = dim3(idivup(nBlocks, maxGridDim), maxGridDim);
  else 
    gridSize = dim3(nBlocks);

  if (pertubation>0.f) {
    if (d_pert == NULL) {
      cudaMalloc((void**)&d_pert, sizeof(float)*count*2); // real and imag
      curandCreateGenerator(&gen, CURAND_RNG_PSEUDO_DEFAULT);
      curandSetPseudoRandomGeneratorSeed(gen, 1234ULL);
    }
    curandGenerateNormal(gen, d_pert, count*2, 0, pertubation);
    compute_rho_phi_kernel<float, true><<<gridSize, blockSize>>>(d_h[slot], d_rho[slot], d_phi[slot], d_re[slot], d_im[slot], d_pert);
  } else {
    compute_rho_phi_kernel<float, false><<<gridSize, blockSize>>>(d_h[slot], d_rho[slot], d_phi[slot], d_re[slot], d_im[slot]);
  }

  cudaDeviceSynchronize();
  checkLastCudaError("compute rho and phi");
}

void vfgpu_extract_faces(int slot, int *pfcount_, gpu_pf_t **pfbuf_, float pert, int meshtype)
{
  const int nfacetypes = meshtype == GLGPU3D_MESH_TET ? 12 : 3;

  const int threadCount = h[slot].count * nfacetypes;
  const int maxGridDim = 1024; // 32768;
  const int blockSize = 256;
  const int nBlocks = idivup(threadCount, blockSize);
  dim3 gridSize; 
  if (nBlocks >= maxGridDim) 
    gridSize = dim3(idivup(nBlocks, maxGridDim), maxGridDim);
  else 
    gridSize = dim3(nBlocks);
  const int sharedSize = blockSize * sizeof(gpu_pf_t) + sizeof(unsigned int);
  
  vfgpu_compute_rho_phi(slot, pert);

  cudaMemset(d_pfcount, 0, sizeof(unsigned int));
  checkLastCudaError("extract faces [0]");
  if (meshtype == GLGPU3D_MESH_TET)
    extract_faces_kernel<float, GLGPU3D_MESH_TET><<<gridSize, blockSize, sharedSize>>>(d_h[slot], d_pfcount, d_pfbuf, d_rho[slot], d_phi[slot]);
  else if (meshtype == GLGPU3D_MESH_HEX)
    extract_faces_kernel<float, GLGPU3D_MESH_HEX><<<gridSize, blockSize, sharedSize>>>(d_h[slot], d_pfcount, d_pfbuf, d_rho[slot], d_phi[slot]);
  checkLastCudaError("extract faces [1]");
 
  cudaMemcpy((void*)&pfcount, d_pfcount, sizeof(unsigned int), cudaMemcpyDeviceToHost);
  printf("pfcount=%d\n", pfcount);
  if (pfcount>0)
    cudaMemcpy(pfbuf, d_pfbuf, sizeof(gpu_pf_t)*pfcount, cudaMemcpyDeviceToHost);
  checkLastCudaError("extract faces [2]");
  
  cudaDeviceSynchronize();

  *pfcount_ = pfcount;
  *pfbuf_ = pfbuf;
}

void vfgpu_extract_edges(int *pecount_, gpu_pe_t **pebuf_, int meshtype)
{
  const int nedgetypes = meshtype == GLGPU3D_MESH_TET ? 7 : 3;

  const int threadCount = h[0].count * nedgetypes;
  const int maxGridDim = 1024; // 32768;
  const int blockSize = 256;
  const int nBlocks = idivup(threadCount, blockSize);
  dim3 gridSize; 
  if (nBlocks >= maxGridDim) 
    gridSize = dim3(idivup(nBlocks, maxGridDim), maxGridDim);
  else 
    gridSize = dim3(nBlocks);
  const int sharedSize = blockSize * sizeof(gpu_pe_t) + sizeof(unsigned int);
  
  cudaMemset(d_pecount, 0, sizeof(unsigned int));
  checkLastCudaError("extract edges [0]");
  if (meshtype == GLGPU3D_MESH_TET)
    extract_edges_kernel<float, GLGPU3D_MESH_TET><<<gridSize, blockSize, sharedSize>>>(d_h[0], d_h[1], d_pecount, d_pebuf, d_phi[0], d_phi[1]);
  else if (meshtype == GLGPU3D_MESH_HEX)
    extract_edges_kernel<float, GLGPU3D_MESH_HEX><<<gridSize, blockSize, sharedSize>>>(d_h[0], d_h[1], d_pecount, d_pebuf, d_phi[0], d_phi[1]);
  checkLastCudaError("extract edges [1]");
 
  cudaMemcpy((void*)&pecount, d_pecount, sizeof(unsigned int), cudaMemcpyDeviceToHost);
  printf("pecount=%d\n", pecount);
  if (pecount>0)
    cudaMemcpy(pebuf, d_pebuf, sizeof(gpu_pe_t)*pecount, cudaMemcpyDeviceToHost);
  checkLastCudaError("extract edges [2]");
  
  cudaDeviceSynchronize();

  *pecount_ = pecount;
  *pebuf_ = pebuf;
}

////////////////////////////////////////// density estimation
__device__
float kernel_gaussian()
{
}

__global__
static void density_estimate(
    const gpu_hdr_t *h,
    int npts, 
    int nlines, 
    const float *pts, 
    const int *acc, float *volume)
{
  const int nidx[3] = {
    blockIdx.x * blockDim.x + threadIdx.x,
    blockIdx.y * blockDim.y + threadIdx.y,
    blockIdx.z * blockDim.z + threadIdx.z};
  if (!valid_nidx(*h, nidx)) return;

  const int nid = nidx2nid(*h, nidx);
  float X[3];
  nidx2pos(*h, nidx, X);

  volume[nid] = inner_product(X, X);
}

void vfgpu_density_estimate(int npts, int nlines, const float *pts, const int *acc)
{
  fprintf(stderr, "npts=%d, nlines=%d\n", npts, nlines);

  float *d_pts;
  int *d_acc;

  cudaMalloc((void**)&d_pts, sizeof(float)*npts*3);
  cudaMalloc((void**)&d_acc, sizeof(int)*nlines);

  if (density == NULL)
    density = (float*)malloc(sizeof(float)*h[0].count);
  if (d_density == NULL) 
    cudaMalloc((void**)&d_density, sizeof(float)*h[0].count);

  cudaMemcpy(d_pts, pts, sizeof(float)*npts*3, cudaMemcpyHostToDevice);
  cudaMemcpy(d_acc, acc, sizeof(int)*nlines, cudaMemcpyHostToDevice);

  const dim3 volumeSize = dim3(h[0].d[0], h[0].d[1], h[0].d[2]);
  const dim3 blockSize = dim3(16, 8, 2);
  const dim3 gridSize = idivup(volumeSize, blockSize);

  density_estimate<<<gridSize, blockSize>>>(d_h[0], npts, nlines, d_pts, d_acc, d_density);

  cudaMemcpy(density, d_density, sizeof(float)*h[0].count, cudaMemcpyDeviceToHost);

  cudaFree(d_pts);
  cudaFree(d_acc);
  
  checkLastCudaError("density estimate");
}
