# Heartcare UI assets

- Layout reference: [Radiologex case study](https://www.belmin.design/projects/radiologex). The Heartcare layout and palette are implemented locally.
- Font: [Inter](https://github.com/rsms/inter), SIL Open Font License; see `Inter-LICENSE.txt`. Chinese text falls back to Microsoft YaHei or PingFang SC. The reference screenshot's exact font is unconfirmed.
- Wordmarks: [Manrope](https://github.com/google/fonts/tree/main/ofl/manrope), SIL Open Font License; see `Manrope-LICENSE.txt`. Both Heartcare titles use the same local variable font at weight 550, with a larger workspace title. This is a visual match to the reference wordmark; its original typeface is unconfirmed.
- Heart symbol: [Lucide heart-pulse](https://lucide.dev/icons/heart-pulse), ISC license; see `Lucide-LICENSE.txt`. Its SVG paths are also embedded in `heartcare.html` for offline rendering.

The Python server serves these assets locally. No font CDN, UI framework, or JavaScript build step is required.
