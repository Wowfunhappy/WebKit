// sanitize-font <in> <out> [comma-separated tags to pass through]
//
// Runs a font through the same OpenType Sanitiser the CoreText polyfill uses, with a chosen set of
// tables passed through, so a fixture can be built with and without one table and the pair compared
// in the browser. Exits non-zero when OTS refuses the font.
#include <opentype-sanitiser.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <set>
#include <vector>
static const size_t kMax = 64u*1024u*1024u;
static std::set<std::string> g_pass;
class V : public ots::OTSStream { public: std::vector<uint8_t> d; size_t o=0;
 size_t size() override { return kMax; }
 bool WriteRaw(const void* p, size_t n) override { if(n>kMax-o) return false; size_t e=o+n; if(e>d.size()) d.resize(e,0); memcpy(d.data()+o,p,n); o=e; return true; }
 bool Seek(off_t p) override { if(p<0||(uint64_t)p>kMax) return false; o=(size_t)p; return true; }
 off_t Tell() const override { return (off_t)o; } };
class C : public ots::OTSContext { public:
 ots::TableAction GetTableAction(uint32_t t) override {
   char s[5]={(char)(t>>24),(char)(t>>16),(char)(t>>8),(char)t,0};
   return g_pass.count(s) ? ots::TABLE_ACTION_PASSTHRU : ots::TABLE_ACTION_DEFAULT; } };
int main(int argc,char**argv){
 if(argc>3){ std::string a=argv[3]; size_t p=0; while(p<a.size()){ size_t c=a.find(',',p); if(c==std::string::npos)c=a.size(); g_pass.insert(a.substr(p,c-p)); p=c+1; } }
 FILE*f=fopen(argv[1],"rb"); if(!f){fprintf(stderr,"open\n");return 2;} fseek(f,0,SEEK_END); long L=ftell(f); fseek(f,0,SEEK_SET);
 std::vector<uint8_t> in(L); if(fread(in.data(),1,L,f)!=(size_t)L) return 2; fclose(f);
 V out; C c; if(!c.Process(&out,in.data(),in.size())){ fprintf(stderr,"REJECT\n"); return 1; }
 FILE*g=fopen(argv[2],"wb"); fwrite(out.d.data(),1,out.d.size(),g); fclose(g);
 fprintf(stderr,"ok %zu -> %zu\n", in.size(), out.d.size()); return 0; }
