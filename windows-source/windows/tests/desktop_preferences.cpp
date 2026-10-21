#include "DesktopPreferences.h"
#include <cassert>
int main(int argc,char**argv){assert(argc==2);std::filesystem::path p=argv[1];assert(!std::filesystem::exists(p));{std::ofstream f(p);f<<"{\"collapsedCount\":9,\"expandedColumns\":5,\"expandedRows\":4}";}auto good=readDesktopLayout(p);assert(good.collapsed==9&&good.columns==5&&good.rows==4);{std::ofstream f(p);f<<"{\"collapsedCount\":\"bad\"}";}auto bad=readDesktopLayout(p);assert(bad.collapsed==6&&bad.columns==6&&bad.rows==6);{std::ofstream f(p);f<<"{\"expandedRows\":99}";}assert(readDesktopLayout(p).rows==9);std::filesystem::remove(p);}
