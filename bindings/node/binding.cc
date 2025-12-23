#include <napi.h>
#include "tree_sitter/parser.h"

extern "C" const TSLanguage *tree_sitter_nim();

// Tree-sitter's Node binding checks an N-API type tag on the language
// external to verify compatibility. We tag the exported object with the
// same constants the core binding uses so Parser.setLanguage accepts it.
static const napi_type_tag LANGUAGE_TYPE_TAG = {
  0x8AF2E5212AD58ABF, 0xD5006CAD83ABBA16
};

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  auto language =
    Napi::External<TSLanguage>::New(env, const_cast<TSLanguage *>(tree_sitter_nim()));
  napi_status status = napi_type_tag_object(env, language, &LANGUAGE_TYPE_TAG);
  if (status != napi_ok) {
    Napi::Error::New(env, "Failed to tag language object").ThrowAsJavaScriptException();
    return exports;
  }
  exports["language"] = language;
  return exports;
}

NODE_API_MODULE(tree_sitter_nim_binding, Init)
