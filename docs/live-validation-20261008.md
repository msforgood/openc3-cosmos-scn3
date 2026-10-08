# Live validation: OpenC3 and all three cFS scenarios (2026-10-08)

The original `open_c3/openc3-cosmos-scn3` Compose directory now includes
`compose.override.yaml`, which points init/API builds and plugin mounts to
the `integration/all-three-scenarios` worktree. `docker compose up -d` from
that directory exits successfully. `openc3-cosmos-init` exits 0,
`scenario-api` reports healthy, and Scenario Runner 1.0.13 serves eight
definitions. The installed cFS target plugin is 7.0.5. Both target
housekeeping screens render and show live telemetry.

The initial HTTP 502 came from a version mismatch: installed Runner 1.0.11
data was paired with the original checkout's 1.0.8 init image. The guarded
upgrade and Compose forwarding configuration now keep the installed release
and source version aligned. Backups of the previous database, gems, and
target plugin are under `open_c3/openc3-cosmos-scn3/backups/`.

| Target | Scenario | Successful steps | Run ID |
| --- | --- | ---: | --- |
| QEMU | CS CRC key recovery and authenticated X-band frame | 18/18 | `ce05b5e3-bd59-4b0d-bac8-d7d36fda6d83` |
| QEMU | TC log overwritten by camera path traversal | 7/7 | `0ffc7e27-1744-4358-a36f-8cd25778c061` |
| QEMU | MM pointer edit causes controller APP_ERROR exit | 11/11 | `7bbfde3c-2613-44f9-b67c-0000a80c30dc` |
| BBB | CS CRC key recovery and authenticated X-band frame | 18/18 | `3df59e11-ecec-4e22-bf4d-a7e398213409` |
| BBB | TC log overwritten by camera path traversal | 7/7 | `e8fa8eb8-c573-474f-b109-f99df0cc37a0` |
| BBB | MM pointer edit causes controller APP_ERROR exit | 11/11 | `91f43c14-e6c9-4a46-b716-e03b14cda83c` |

These results come from the installed Scenario API run and step-event
records, using the real QEMU and BBB TC/TM interfaces. The CRC procedure
does not print the reconstructed key; it proves use of that key by verifying
and decrypting an authenticated X-band frame. Scenario 3 intentionally
terminates `PAYLOAD_CTRL_APP`, so restart cFS before repeating it. Keep
existing `/cf/log/tc*.log` files during restart; the logger resumes at the
next available number.

After target plugin installation, BBB was still transmitting UDP telemetry
on its USB link, but the OpenC3 operator receive counter stayed at zero.
`docker compose up -d --force-recreate --no-deps openc3-operator` restored
BBB receive traffic; the Scenario Runner BBB housekeeping screen then showed
live packets. This is a recovery observation, not a definitive diagnosis of
the Docker Desktop UDP forwarding internals.

## Subsequent Runner 1.0.14 and XKEY flag validation

OpenC3 was upgraded to Scenario Runner 1.0.14. Its init exited 0, the
Scenario API was healthy, the Runner URL returned HTTP 200, and the API
listed eight definitions. Both flight targets' TM and X-band interface
receive counters increased. The focused CRC tests passed 8/8 and the Runner
UI component tests passed 19/19.

The initial BBB 1.0.14 CRC run recovered all 16 key bytes but failed its
final `xband_payload_invalid` check. The new Runner expected a decrypted
`flag{crc_oracle}` payload while both deployed XKEY modules still encrypted
the older synthetic housekeeping payload. The updated ARM XKEY module was
built for each target, deployed with the previous module backed up, and
verified by SHA-256 and the new flag payload in the binary. No existing TC
log or photo was removed.

| Target | Scenario | Successful steps | 1.0.14 run ID |
| --- | --- | ---: | --- |
| QEMU | CS CRC key recovery and X-band flag | 18/18 | `6a171a36-862f-41f4-8974-818a5214ffa6` |
| QEMU | TC log overwritten by camera path traversal | 7/7 | `d9b2825b-e5b1-45ab-969d-5b0c81508fa6` |
| QEMU | MM pointer edit causes controller APP_ERROR exit | 11/11 | `8055c3a1-4ba6-4b72-a81b-d64d9013027d` |
| BBB | CS CRC key recovery and X-band flag | 18/18 | `7f075db4-402c-4e48-985b-bdf213bd0380` |
| BBB | TC log overwritten by camera path traversal | 7/7 | `c58f1807-e98a-4088-800c-29db74f60f24` |
| BBB | MM pointer edit causes controller APP_ERROR exit | 11/11 | `9c565783-2ade-40b1-8a70-bae77a4b0fcc` |

The successful X-band steps authenticated a fresh AES-GCM frame and
decrypted `flag{crc_oracle}` on both targets. The recovered per-start keys
are in the restricted lab run results and are intentionally omitted from
this document; Runner 1.0.14 displays them in the result UI.
The 1.0.14 UI component tests cover key and flag rendering; a separate
browser automation check was blocked by the browser tool's URL policy, so
the post-upgrade page was verified by HTTP/API response rather than a visual
browser inspection.

After the scenario 3 runs, both cFS targets were restarted to restore
`PAYLOAD_CTRL_APP` for another demonstration. Existing TC logs and photos
were preserved, the new XKEY module remained deployed, and TO_LAB was
re-enabled. Both targets' ordinary TM and X-band receive counters increased;
the controller and pulse apps reported their normal ready states.
