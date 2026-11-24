#include "libcamerasrc_support.h"

#include <gst/gst.h>

#include "openhd_spdlog.h"
#include "openhd_spdlog_include.h"

namespace {

bool find_openhd_properties() {
  if (!gst_is_initialized() && !gst_init_check(nullptr, nullptr, nullptr)) {
    return false;
  }
  GstElementFactory* factory = gst_element_factory_find("libcamerasrc");
  if (factory == nullptr) {
    return false;
  }
  bool found = false;
  // Loads the plugin, but doesn't create an element (which could already
  // claim the camera).
  auto* loaded =
      GST_PLUGIN_FEATURE(gst_plugin_feature_load(GST_PLUGIN_FEATURE(factory)));
  if (loaded != nullptr) {
    const GType type =
        gst_element_factory_get_element_type(GST_ELEMENT_FACTORY(loaded));
    if (type != G_TYPE_INVALID) {
      auto* klass = static_cast<GObjectClass*>(g_type_class_ref(type));
      // "denoise" only exists on the OpenHD / Arducam libcamerasrc
      found = g_object_class_find_property(klass, "denoise") != nullptr;
      g_type_class_unref(klass);
    }
    gst_object_unref(loaded);
  }
  gst_object_unref(factory);
  return found;
}

}  // namespace

bool openhd::libcamerasrc_has_openhd_properties() {
  static const bool has_properties = [] {
    const bool found = find_openhd_properties();
    openhd::log::get_default()->info(
        "libcamerasrc {} the OpenHD properties (rotation, flip, IQ)",
        found ? "has" : "doesn't have");
    return found;
  }();
  return has_properties;
}
