# MBS: 5G NR Multicast/Broadcast (Rel-17) with an open 5G core and the OCUDU gNB

Over-the-air 5G NR broadcast (point-to-multipoint, PTM) on software-defined radio:

- **5gcore/** – 5G core with MBS (5G-MAG reference tools, Open5GS based: AMF, MB-SMF, MB-UPF, …) and an AF/AS
  that creates broadcast sessions and streams video or text. Runs from pre-built, digest-pinned Docker images.
- **gnb/** – OCUDU gNB with our MBS extension (NGAP broadcast session, E1AP/F1AP MBS contexts, SIB20/MCCH,
  broadcast MRB, G-RNTI MTCH scheduling) in a Docker image that includes UHD and the USRP B210 firmware/FPGA images.
- **ue/** – receiver (srsRAN-based MBS UE); to be added.

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

## Citation

R. Paudyal, A. N. B. Emran, R. Upadhyay, A. Bhuyan, D. Wijesekera, "5G Multicast-Broadcast On Air: An Open SDR Testbed and
Experimental Characterization of MBS," ACM WiNTECH 2026. Preprint: https://engrxiv.org/preprint/view/8250
