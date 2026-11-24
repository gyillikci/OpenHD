#ifndef OPENHD_LIBCAMERASRC_SUPPORT_H
#define OPENHD_LIBCAMERASRC_SUPPORT_H

namespace openhd {

// True if the libcamerasrc GStreamer element has the properties of the
// OpenHD / Arducam libcamera (rotation, flips, IQ, denoise, shutter, ...).
// The stock libcamerasrc of Raspberry Pi OS (so also on every RPI 5) doesn't
// have them, and gst_parse_launch fails on an unknown property. Checked once,
// the first call initialises GStreamer if needed.
bool libcamerasrc_has_openhd_properties();

}  // namespace openhd

#endif  // OPENHD_LIBCAMERASRC_SUPPORT_H
