-- The virtio sound card's volume is the device's (Henge). When WirePlumber selects a route
-- for that card, it keeps the volume and mute the card has, not a stored or default one.

cutils = require ("common-utils")
log = Log.open_topic ("s-henge")

function isHengeCard (device)
  local p = device.properties
  return p ["device.api"] == "alsa" and p ["alsa.driver_name"] == "virtio_snd"
end

SimpleEventHook {
  name = "henge/keep-device-volume",
  after = { "device/apply-route-props" },
  before = { "device/apply-routes" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-routes" },
    },
  },
  execute = function (event)
    local device = event:get_subject ()
    local selected = event:get_data ("selected-routes")
    if not selected or not isHengeCard (device) then
      return
    end

    local now = {}
    for p in device:iterate_params ("Route") do
      local route = cutils.parseParam (p, "Route")
      if route and route.props then
        now [tostring (route.device)] = route.props
      end
    end

    local kept = {}
    for device_id, route in pairs (selected) do
      route = Json.Raw (route):parse ()
      local cur = now [device_id]
      if not cur or not cur.channelVolumes then
        -- No route yet, so no volume to keep: turn the route on without props, which leaves the mixer as it is.
        log:info (device, "route " .. tostring (route.index) .. " on, mixer untouched")
        device:set_param ("Route", Pod.Object {
          "Spa:Pod:Object:Param:Route", "Route",
          index = route.index,
          device = tonumber (device_id),
          save = false,
        })
        goto next
      end
      local props = route.props or {}
      props.channelVolumes = Json.Array (cur.channelVolumes)
      props.mute = cur.mute
      if props.channelMap then
        props.channelMap = Json.Array (props.channelMap)
      end
      if props.iec958Codecs then
        props.iec958Codecs = Json.Array (props.iec958Codecs)
      end
      kept [device_id] = Json.Object { index = route.index, props = Json.Object (props) }:to_string ()
      ::next::
    end
    event:set_data ("selected-routes", kept)
  end
}:register ()
