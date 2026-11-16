# MBS: 5G NR Multicast/Broadcast (Rel-17) with an open 5G core and the OCUDU gNB

## About

An open, end-to-end Direct-to-Mobile (D2M) testbed in the cellular band, based on 3GPP Rel-17 5G NR Multicast/Broadcast
Services (MBS) over software-defined radio. A 5G core creates a broadcast session, an OCUDU gNB sends it once over the
air on a group RNTI with a USRP B210, and any number of srsRAN-based receive-only UEs (no SIM, no uplink) decode it and
play the video live.

## Components

Over-the-air 5G NR broadcast (point-to-multipoint, PTM) on software-defined radio:

- **5gcore/** – 5G core with MBS (5G-MAG reference tools, Open5GS based: AMF, MB-SMF, MB-UPF, …) and an AF/AS
  that creates broadcast sessions and streams video or text. Runs from pre-built, digest-pinned Docker images.
- **gnb/** – OCUDU gNB with our MBS extension (NGAP broadcast session, E1AP/F1AP MBS contexts, SIB20/MCCH,
  broadcast MRB, G-RNTI MTCH scheduling) in a Docker image that includes UHD and the USRP B210 firmware/FPGA images.
- **ue/** – receive-only MBS UE (srsRAN_4G with our MBS receiver: SIB20/MCCH, G-RNTI PDCCH/PDSCH, MRB → UDP video),
  prebuilt and self-contained: the receiver, every library it needs (UHD, FFTW, Boost, glibc, …) and the B210 firmware
  are in the folder, so it starts right after `git clone`, with no build and no Docker.

```
 AF/AS ──Nmbsmf──► MB-SMF ──► AMF ──NGAP──► gNB (B210) ═══ MTCH on G-RNTI 0xFE01 ═══► UE 1 … UE N
   └──── GTP-U ───► MB-UPF ──IP multicast (N3mb)──┘            one transmission, any number of receivers
```

## Requirements (gNB PC)

| | |
|---|---|
| OS | Linux x86-64 (tested Ubuntu 22.04, kernel 5.15 low-latency/RT). CPU with AVX2 (Intel Haswell / AMD Zen or newer) |
| Software | **Docker** (Engine 24+ with the compose plugin). Nothing else: core, gNB, UHD and B210 images are in containers |
| Radio | Ettus **USRP B210** on a **USB 3** port, antennas or cabled setup for band n78 |
| Spectrum | n78 (3489.42 MHz) over the air needs a licence or a shielded/cabled setup |

## Quick start (gNB PC)

```bash
git clone https://github.com/rajendra1124/mbs.git && cd mbs

./5gcore/start.sh                       # core + AF/AS; also generates media/demo.ts (licence-free test pattern)
./5gcore/add-subscriber.sh <IMSI> <K> <OPc>   # once per UE (PLMN 999/70), or use the web UI at http://127.0.0.1:9999
sudo ./gnb/host-tune.sh                 # optional, recommended: real-time host tuning
DETACH=1 ./gnb/start.sh                 # gNB container with the B210 (pulls ghcr.io/rajendra1124/mbs-gnb)
./5gcore/activate-broadcast.sh          # create the broadcast session and stream video (1.5 Mb/s)
#   MODE=text ./5gcore/activate-broadcast.sh   -> timestamped text messages instead
```

Activate **one** session per gNB start: the gNB gives the first session G-RNTI 0xFE01 (what the receivers listen to) and
later sessions 0xFE02, 0xFE03, … To start a new session, restart the gNB first.

Check that it is broadcasting:

```bash
grep -E "Joined multicast group|MTCH: rnti=0xfe01" gnb/logs/gnb.log | tail -3
```

Stop: `./gnb/stop.sh && ./5gcore/stop.sh` (subscribers are kept).

## Quick start (UE PC)

Any number of UE PCs can receive the broadcast. The UE is receive-only, so it needs no SIM, subscriber entry or uplink.

| | |
|---|---|
| OS | Linux x86-64 (tested on Ubuntu 24.04). CPU with AVX2/FMA (Intel Haswell / AMD Zen or newer) |
| Software | Nothing to build. Optional: VLC, ffplay or mpv to watch the video (`sudo apt install vlc`) |
| Radio | USRP **B200/B210** on a **USB 3** port, tuned by default to the gNB cell above |

```bash
git clone https://github.com/rajendra1124/mbs.git && cd mbs

sudo ./ue/setup-usb.sh                  # once per PC: USB permissions for the USRP, then replug it
./ue/start.sh                           # receiver + video player; Ctrl-C stops both
#   DETACH=1 ./ue/start.sh  -> background, no player; ./ue/stop.sh stops it
#   RF_GAIN=60 PLAYER=ffplay RECORD=0 ./ue/start.sh   (all settings: ue/config/ue.env)
```

The UE can start before or after `activate-broadcast.sh`; it keeps searching until the cell is on air. The log is
`ue/logs/ue.log`, with a `slots=… crc_ok=… sdus=…` line every second. The received MPEG-TS goes to
`udp://127.0.0.1:5005` and is also recorded to `/dev/shm/mbs_ue/received_<time>.ts` (in RAM; `RECORD=0` turns this
off, `SAVE_DIR=` changes the folder). `./ue/check-usrp.sh` probes the radio with the bundled UHD. With several USRPs
attached, select one with `RF_ARGS='type=b200,serial=XXXXXXX,num_recv_frames=512'`.

How it is self-contained: `ue/start.sh` runs `ue/bin/srsue_mbs` through the bundled loader
(`ue/lib/ld-linux-x86-64.so.2 --library-path ue/lib`). The UE therefore uses only the libraries in `ue/lib`, whatever
the host has installed (or not), and UHD reads the B2xx images from `ue/share/uhd/images`.

## Cell and broadcast configuration

| Parameter | Value |
|---|---|
| Band / carrier | n78 TDD, 3489.42 MHz (NR-ARFCN 632628), 20 MHz, 30 kHz SCS, 51 PRB |
| TDD | 5 ms: 6 DL, 1 special, 3 UL slots |
| PLMN / TAC / slice | 999/70, TAC 1, SST 1 (SD ffffff) |
| Broadcast | MTCH on G-RNTI 0xFE01, MCS 6 (QPSK), up to 48 PRB (CORESET#0); MCCH every 160 ms |
| Media | MPEG-TS CBR 1.5 Mb/s, 7 TS packets per GTP-U datagram |
| Measured | 1.5 Mb/s for 3 h with 0 packet loss to the gNB, 34 % of the broadcast PRB grid, gNB residence p50 2.9 ms |

Edit `gnb/config/gnb.yml` (frequency, gain, PLMN) and `5gcore/configs/*.yaml` to change them; keep PLMN/slice consistent.

## Addresses

| | |
|---|---|
| Docker network `5g-mag` | 10.33.33.0/24 (bridge `br-5g-mag`, host side 10.33.33.1) |
| AMF NGAP | 10.33.33.19, published on 127.0.0.1:38412 (the gNB uses host networking) |
| MB-SMF / MB-UPF / AF/AS | 10.33.33.18 / 10.33.33.3 / 10.33.33.10 |
| gNB NG-U | 10.33.33.1:2152; joins the MBS multicast group (239.0.0.x:2152) announced over NGAP |
| UE IP pool | 10.45.0.0/16 (DNN `internet`) |

## Rebuilding the gNB image

`gnb/Dockerfile` clones upstream OCUDU at commit `1ba4cdf2ed` and applies `gnb/patches/0001-ocudu-mbs-broadcast.patch`
(our MBS changes). Build locally with `docker build -t ghcr.io/rajendra1124/mbs-gnb:latest gnb/`.

## Rebuilding the UE bundle

`ue/build-from-source.sh` clones upstream srsRAN_4G at tag `release_25_10` (commit `6bcbd9e5bf`), applies
`ue/patches/0001-srsran4g-mbs-receiver.patch` (our MBS receiver), builds for x86-64-v3, runs the MBS unit tests and
refreshes `ue/bin`, `ue/lib` and `ue/share`. Run it on Ubuntu 24.04 x86-64 (`INSTALL_DEPS=1` installs the build
packages and UHD 4.11 from the Ettus PPA). `SRC_TREE=/path/to/srsRAN_4G ./ue/build-from-source.sh` bundles a tree you
are developing in instead. `ue/share/BUILDINFO` records what the current bundle was built from.

## Status and known limitations

This is a research prototype, not a full Rel-17 conformance implementation. Known gaps: MCCH is scrambled with SI-RNTI
(not MCCH-RNTI) and its window is in a CSI-RS slot; broadcast reuses the F1AP/E1AP multicast procedures; MBS PDCP runs in
the DU; MCS and the 48-PRB limit are fixed. MB-SMF session release is skipped (the core image crashes on release);
restart `smf_mb-smf upf_mb-upf amf_with_mbs` after many sessions.

## Licences

- OCUDU and our patch to it: BSD-3-Clause-Open-MPI (see the OCUDU LICENSE, shipped in the image at `/usr/share/doc/ocudu/LICENSE`).
- 5G-MAG reference tools (core images, AF/AS test code): 5G-MAG Public License v1.0, see `5gcore/LICENSE-5G-MAG.md` and
  `5gcore/ATTRIBUTION_NOTICE-5G-MAG` (the core images include Open5GS, AGPL-3.0).
- UHD: GPL-3.0 (Ettus Research), installed from Ubuntu packages inside the gNB image.
- UE (`ue/`): srsRAN_4G and our patch to it are AGPL-3.0 (`ue/LICENSE-srsRAN`, `ue/COPYRIGHT-srsRAN`); the source of the
  bundled receiver is upstream `release_25_10` plus `ue/patches/`. The bundled libraries are unmodified Ubuntu 24.04 /
  Ettus PPA packages under their own licences (UHD GPL-3.0, FFTW GPL-2.0+, glibc LGPL-2.1+, Boost BSL-1.0, …);
  `ue/share/THIRD_PARTY.txt` lists the package and version of each file, and `apt-get source <package>` fetches its source.

## Citation

R. Paudyal, A. N. B. Emran, R. Upadhyay, A. Bhuyan, D. Wijesekera, "5G Multicast-Broadcast On Air: An Open SDR Testbed and
Experimental Characterization of MBS," ACM MobiCom @WiNTECH 2026. 

If you use this testbed or build upon our work in your research, please cite our paper:

```bibtex
@inproceedings{10.1145/3831662.3844176,
  author    = {Paudyal, Rajendra and Emran, Al Nahian Bin and Upadhyay, Rajendra and Bhuyan, Arupjyoti and Wijesekera, Duminda},
  title     = {5G Multicast-Broadcast On Air: An open SDR Testbed and Experimental Characterization of MBS},
  year      = {2026},
  isbn      = {9798400728792},
  publisher = {Association for Computing Machinery},
  address   = {New York, NY, USA},
  url       = {https://doi.org/10.1145/3831662.3844176},
  doi       = {10.1145/3831662.3844176},
  booktitle = {Proceedings of the 20th ACM Workshop on Wireless Network Testbeds, Experimental Evaluation \& Characterization},
  pages     = {121--128},
  numpages  = {8},
  keywords  = {5G, MBS, PTM, software-defined-radio, testbed, over-the-air},
  location  = {Austin, TX, USA},
  series    = {WiNTECH '26}
}
```

