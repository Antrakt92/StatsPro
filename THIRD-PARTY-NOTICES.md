# Third-Party Notices

StatsPro bundles these runtime libraries so release packages use the same reviewed
source that is present in the source tree. Source revisions, source archives, and
license texts are pinned below. SHA256 values for text files are computed after
normalizing line endings to LF, so Windows and Linux checkouts validate the same
content. The StatsPro addon code is MIT-licensed; bundled libraries keep their
upstream licenses.

## libs/LibStub/LibStub.lua

- Project: LibStub
- Source: https://repos.curseforge.com/wow/libstub/!svn/rvr/103/trunk/LibStub.lua
- Source revision: r103
- License: Public Domain
- SHA256: 43C1355A2BED1C426BD33ABB53B8ABD0A7C6E9B3E295A73FA98BEE73CE2CCC50

## libs/CallbackHandler-1.0/CallbackHandler-1.0.lua

The standalone archive declares `BSD-2.0` but does not include a separate
license file. The shipped BSD-2-Clause notice combines the Ace3 Development
Team copyright line with the exact pinned SPDX two-clause terms; the three
inputs are preserved below instead of substituting the broader Ace3 license.

- Project: CallbackHandler-1.0
- Source: https://www.curseforge.com/wow/addons/callbackhandler/files/4167614
- Source revision: r26
- Source artifact: CallbackHandler-1.0-1.0.9.zip
- Source artifact SHA256: 75B11A307243D2DBBC80D9D4EB83A7824B4179A097470A98F4CD460C07E0299D
- License: BSD-2-Clause
- License declaration: https://repos.curseforge.com/wow/callbackhandler/!svn/rvr/26/trunk/CallbackHandler-1.0.toc
- License declaration SHA256: 7350135554CAE47520754A72C4F076555ECC279F51A4EE0F1E16DABF7E1119E2
- Copyright notice: https://raw.githubusercontent.com/WoWUIDev/Ace3/9f61bbab1cf384488251fd85b2e9c1e2081b42a2/LICENSE.txt
- Copyright notice SHA256: 6096327FD5DCE56B74C6C7F1BFD134DBBB78C447F57D900F37064FFFA6CBCCE7
- License template: https://raw.githubusercontent.com/spdx/license-list-data/421fbabbe80c94c58c12316af1bc6a2dca2362bc/text/BSD-2-Clause.txt
- License template SHA256: F32FB3B417A194167CFAD068223FC975BA96C5960513A10F66A3C28720AEC1DF
- License text: LICENSES/CallbackHandler-1.0-BSD-2-Clause.txt
- License text SHA256: BB630CB510B8EBAFC0F04C82A2BA1D21BB13598DB5B45C890185E71E96E5D933
- SHA256: 84A15AF505E728AC5E5EB6A8EABA8989D1131D5F8BA14D11ABCFE4CE086DE3C1

## libs/LibSharedMedia-3.0/LibSharedMedia-3.0.lua

The CurseForge project page currently says All Rights Reserved, while the
immutable bundled source revision explicitly declares LGPL v2.1. StatsPro pins
that per-file declaration and includes the corresponding GNU license text.

- Project: LibSharedMedia-3.0
- Source: https://www.curseforge.com/wow/addons/libsharedmedia-3-0/files/8691989
- Source revision: r176
- Source artifact: LibSharedMedia-3.0-v12.1.0.zip
- Source artifact SHA256: 14BEB11FCC1082C7B846960FDE39596147A769A807601ECB0AEC4DE60750956D
- License: LGPL-2.1-only
- License declaration: https://repos.curseforge.com/wow/libsharedmedia-3-0/!svn/rvr/176/trunk/LibSharedMedia-3.0/LibSharedMedia-3.0.lua
- License declaration SHA256: EA359E44EAE4355C51A49A69960C878889EE26ADAC9D72D1362C22A3DB6AF6D0
- License text: LICENSES/LibSharedMedia-3.0-LGPL-2.1.txt
- License text source: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.txt
- License text SHA256: 20E50FE7AAE3E56378EBF0417D9DE904F55A0E61E4DF315333E632A4D3555D95
- SHA256: B2650FC5ACBFF310C7F7A23A36C8026A99D2441982D4B4F63AFB76489D56B214

## SwiftStats (derived portions, no vendored file)

StatsPro contains no vendored SwiftStats file; the import reads a user's
installed SwiftStats saved variables at runtime and carries over compatible
settings. The notice below records the upstream project, version, and license
for those derived portions.

- Project: SwiftStats
- Author: TaylorSay
- Source: https://www.curseforge.com/wow/addons/swiftstats
- Version: v2.1
- License: MIT
- Scope: derived portions only; no SwiftStats file is vendored in this repository
