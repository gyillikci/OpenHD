/******************************************************************************
 * OpenHD
 *
 * Licensed under the GNU General Public License (GPL) Version 3.
 *
 * This software is provided "as-is," without warranty of any kind, express or
 * implied, including but not limited to the warranties of merchantability,
 * fitness for a particular purpose, and non-infringement. For details, see the
 * full license in the LICENSE file provided with this source code.
 *
 * Non-Military Use Only:
 * This software and its associated components are explicitly intended for
 * civilian and non-military purposes. Use in any military or defense
 * applications is strictly prohibited unless explicitly and individually
 * licensed otherwise by the OpenHD Team.
 *
 * Contributors:
 * A full list of contributors can be found at the OpenHD GitHub repository:
 * https://github.com/OpenHD
 *
 * © OpenHD, All Rights Reserved.
 ******************************************************************************/

#include "ethernet_link.h"

#include <arpa/inet.h>
#include <unistd.h>

#include <cstring>
#include <iostream>
#include <sstream>

#include "config_paths.h"
#include "openhd_config.h"
#include "openhd_util.h"
#include "openhd_util_filesystem.h"

static std::string ETHERNET_FILE_PATH =
    std::string(getConfigBasePath()) + "ethernet.txt";

namespace {

// ethernet.txt may set GROUND_UNIT_IP, AIR_UNIT_IP, VIDEO_PORT and
// TELEMETRY_PORT, one KEY=VALUE per line ('#' starts a comment line). Keys it
// doesn't set keep their value.
void apply_ethernet_file(const std::string& content, std::string& ground_ip,
                         std::string& air_ip, int& video_port,
                         int& telemetry_port) {
  std::istringstream stream(content);
  std::string line;
  while (std::getline(stream, line)) {
    OHDUtil::trim(line);
    const auto pos = line.find('=');
    if (line.empty() || line[0] == '#' || pos == std::string::npos) {
      continue;
    }
    auto key = line.substr(0, pos);
    auto value = line.substr(pos + 1);
    OHDUtil::trim(key);
    OHDUtil::trim(value);
    if (key == "GROUND_UNIT_IP" && !value.empty()) {
      ground_ip = value;
    } else if (key == "AIR_UNIT_IP" && !value.empty()) {
      air_ip = value;
    } else if (key == "VIDEO_PORT" || key == "TELEMETRY_PORT") {
      const auto port = OHDUtil::string_to_int(value);
      if (port.has_value() && port.value() > 0 && port.value() <= 65535) {
        (key == "VIDEO_PORT" ? video_port : telemetry_port) = port.value();
      } else {
        std::cerr << "ethernet.txt: ignoring " << line << std::endl;
      }
    }
  }
}

}  // namespace

EthernetLink::EthernetLink(const openhd::Config& config, OHDProfile profile)
    : m_profile(profile), m_config(config) {
  // Defaults < IPs from OpenHD-SysUtils (if set) < ethernet.txt. The ports of
  // OpenHD-SysUtils are not used: they default to 5000 / 5600, and 5600 is
  // the port the ground forwards the video to locally.
  if (!config.GROUND_UNIT_IP.empty()) {
    GROUND_UNIT_IP = config.GROUND_UNIT_IP;
  }
  if (!config.AIR_UNIT_IP.empty()) {
    AIR_UNIT_IP = config.AIR_UNIT_IP;
  }
  const auto content =
      OHDFilesystemUtil::opt_read_file(ETHERNET_FILE_PATH, false);
  if (content.has_value()) {
    apply_ethernet_file(content.value(), GROUND_UNIT_IP, AIR_UNIT_IP,
                        VIDEO_PORT, TELEMETRY_PORT);
  }
  std::cout << "Ethernet link: ground " << GROUND_UNIT_IP << ", air "
            << AIR_UNIT_IP << ", video port " << VIDEO_PORT
            << ", telemetry port " << TELEMETRY_PORT << std::endl;

  // Initialize either air or ground unit based on the profile
  if (m_profile.is_air) {
    initialize_air_unit();
  } else {
    initialize_ground_unit();
  }
}

EthernetLink::EthernetLink(OHDProfile profile)
    : EthernetLink(openhd::load_config(), profile) {}

EthernetLink::~EthernetLink() {
  // Stop background receivers
  if (m_video_rx) m_video_rx->stopBackground();
  if (m_telemetry_rx) m_telemetry_rx->stopBackground();
}

void EthernetLink::initialize_air_unit() {
  // Initialize video transmitter for sending video to the ground unit
  m_video_tx =
      std::make_unique<openhd::UDPForwarder>(GROUND_UNIT_IP, VIDEO_PORT);

  // Initialize telemetry transmitter and receiver for bidirectional telemetry
  m_telemetry_tx =
      std::make_unique<openhd::UDPForwarder>(GROUND_UNIT_IP, TELEMETRY_PORT);
  m_telemetry_rx = std::make_unique<openhd::UDPReceiver>(
      "0.0.0.0", TELEMETRY_PORT, [this](const uint8_t* data, std::size_t len) {
        handle_telemetry_data(data, len);  // Process incoming telemetry
      });

  // Start telemetry receiver in the background
  if (m_telemetry_rx) m_telemetry_rx->runInBackground();
}

void EthernetLink::initialize_ground_unit() {
  // Initialize video receiver for receiving video from the air unit
  m_video_rx = std::make_unique<openhd::UDPReceiver>(
      "0.0.0.0", VIDEO_PORT, [this](const uint8_t* data, std::size_t len) {
        handle_video_data(0, data, len);  // Process incoming video
      });

  // Initialize telemetry transmitter and receiver for bidirectional telemetry
  m_telemetry_tx =
      std::make_unique<openhd::UDPForwarder>(AIR_UNIT_IP, TELEMETRY_PORT);
  m_telemetry_rx = std::make_unique<openhd::UDPReceiver>(
      "0.0.0.0", TELEMETRY_PORT, [this](const uint8_t* data, std::size_t len) {
        handle_telemetry_data(data, len);  // Process incoming telemetry
      });

  // Start video and telemetry receivers in the background
  if (m_video_rx) m_video_rx->runInBackground();
  if (m_telemetry_rx) m_telemetry_rx->runInBackground();
}

void EthernetLink::transmit_telemetry_data(TelemetryTxPacket packet) {
  // Send telemetry data to the destination
  if (m_telemetry_tx) {
    m_telemetry_tx->forwardPacketViaUDP(packet.data->data(),
                                        packet.data->size());
  }
}

void EthernetLink::transmit_video_data(
    int stream_index,
    const openhd::FragmentedVideoFrame& fragmented_video_frame) {
  // Send video data fragments to the destination
  if (m_video_tx) {
    for (const auto& fragment : fragmented_video_frame.rtp_fragments) {
      m_video_tx->forwardPacketViaUDP(fragment->data(), fragment->size());
    }
  }
}

void EthernetLink::transmit_audio_data(
    const openhd::AudioPacket& audio_packet) {
  // Currently not implemented for EthernetLink
}

void EthernetLink::handle_video_data(int stream_index, const uint8_t* data,
                                     int data_len) {
  // Forward incoming video data to the upper layer
  on_receive_video_data(stream_index, data, data_len);
}

void EthernetLink::handle_telemetry_data(const uint8_t* data, int data_len) {
  // Forward incoming telemetry data to the upper layer
  auto shared = std::make_shared<std::vector<uint8_t>>(data, data + data_len);
  on_receive_telemetry_data(shared);
}