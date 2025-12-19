#include <napi.h>
#include "tree_sitter/parser.h"

extern "C" TSLanguage *tree_sitter_nim();

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  exports["language"] = Napi::External<void>::New(env, tree_sitter_nim());
  return exports;
}

NODE_API_MODULE(tree_sitter_nim_binding, Init)
