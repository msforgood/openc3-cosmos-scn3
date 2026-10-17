# Ground station procedure: request the stored message downlink from INST
#
# INST DOWNLINK_MSG makes the instrument send the INST MESSAGE packet
# 5 times, 1 second apart. This procedure sends the telecommand and
# prints every MESSAGE frame as it is received.

DOWNLINK_COUNT = 5

# Make sure the instrument is connected before commanding
interface = get_interface("INST_INT")
if interface["state"] != "CONNECTED":
    raise RuntimeError(f"INST_INT is {interface['state']}, connect it before sending DOWNLINK_MSG")

start_count = tlm("INST MESSAGE RECEIVED_COUNT")
print(f"MESSAGE packets received so far: {start_count}")

cmd("INST DOWNLINK_MSG")

for i in range(1, DOWNLINK_COUNT + 1):
    # Each frame is 1 second apart so allow a little margin per frame
    wait_check(f"INST MESSAGE RECEIVED_COUNT >= {start_count + i}", 3)
    seq = tlm("INST MESSAGE SEQ")
    text = tlm("INST MESSAGE TEXT")
    print(f"[{i}/{DOWNLINK_COUNT}] SEQ={seq} TEXT={text}")

check(f"INST MESSAGE SEQ == {DOWNLINK_COUNT}")
print("Downlink complete")
