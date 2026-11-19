# Index video on demand in lightweight playback

Loupe shows a poster for videos and animated images by default. An autoplay setting lets the current item start playing during browsing.

Opening a video in Loupe must avoid a full-file index, including on network volumes. Lightweight playback must step to the exact adjacent presentation frame in either direction. It may take longer on the first step in a region that needs to be read or decoded, in exchange for lower background load during browsing.
