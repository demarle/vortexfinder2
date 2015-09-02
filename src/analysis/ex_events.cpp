#include "def.h"
#include "common/DataInfo.pb.h"
#include "common/VortexTransition.h"
#include <cstdio>

int main(int argc, char **argv)
{
  if (argc < 4) {
    fprintf(stderr, "Usage: %s <dataname> <ts> <tl>\n", argv[0]);
    return EXIT_FAILURE;
  }

  const std::string dataname = argv[1];
  const int ts = atoi(argv[2]), 
            tl = atoi(argv[3]);

  VortexTransition vt;
  vt.LoadFromFile(dataname, ts, tl);
  vt.ConstructSequence();
  vt.PrintSequence();

  return 0;
}
