# libusb

`libusb-1.0.dylib` はPyPIの `libusb-package==1.0.30.0` に含まれるmacOS arm64 / x86_64版を
`lipo`でまとめたUniversal版。コードは変更していない。
ライセンスはLGPL-2.1-or-later。本文は `COPYING` に同梱。

- プロジェクト：https://libusb.info/
- 対応ソース：https://github.com/libusb/libusb/tree/v1.0.30
- ソース配布：https://github.com/libusb/libusb/releases/tag/v1.0.30
- パッケージ：https://pypi.org/project/libusb-package/1.0.30.0/

動的ロードのため、アプリの `Contents/Resources/libusb-1.0.dylib` を互換ライブラリへ
差し替えて利用できる。libusbのコードは変更していない。
