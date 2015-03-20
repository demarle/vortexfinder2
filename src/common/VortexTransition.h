#ifndef _VORTEX_TRANSITION_H
#define _VORTEX_TRANSITION_H

#include "common/VortexTransitionMatrix.h"
#include "common/VortexSequence.h"

class VortexTransition 
{
public:
  VortexTransition();
  ~VortexTransition();
  
  int ts() const {return _ts;}
  int tl() const {return _tl;}

  void LoadFromFile(const std::string &dataname, int ts, int tl);
  void SaveToDotFile(const std::string &filename) const;

  VortexTransitionMatrix Matrix(int t) const;
  void AddMatrix(const VortexTransitionMatrix& m);
  int Transition(int t, int i, int j) const;

  void ConstructSequence();
  int SequenceIdx(int t, int lid) const;

  int MaxNVorticesPerFrame() const {return _max_nvortices_per_frame;}

  const std::vector<struct VortexSequence> Sequences() const {return _seqs;}

private:
  int NewVortexSequence(int ts);

  std::string NodeToString(int i, int j) const;

private:
  int _ts, _tl;
  std::map<int, VortexTransitionMatrix> _matrices;
  std::vector<struct VortexSequence> _seqs;
  std::map<std::tuple<int, int>, int> _seqmap; // <time, lid>, gid
  std::map<int, int> _nvortices_per_frame;
  int _max_nvortices_per_frame;

  std::vector<struct VortexEvent> _events;
};

#endif
