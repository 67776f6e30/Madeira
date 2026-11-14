# Google Drive 다운로드 연동 조사

조사일: 2026-11-14 (Asia/Seoul). 기준 커밋: `2d81c19`.
작업 브랜치: `codex/google-drive-download-research`.

구현 및 OAuth placeholder 설정 방법은 [GOOGLE_DRIVE.md](GOOGLE_DRIVE.md)에 정리했다.
아래 내용은 구현 전 조사 기록이며, 실제 구현은 시스템 브라우저 OAuth와 PKCE,
128 MiB 구간 저장 방식을 사용한다.

Google Drive의 지정 폴더를 Madeira 라이브러리의 다운로드 소스로 추가하는 것은 기술적으로 가능하다. 사용자가 지정한 **ZIP 파일과 압축을 푼 게임 폴더**를 모두 지원할 수 있다. 권장 구성은 Google Sign-In과 Drive API, iOS의 백그라운드 `URLSession`, 로컬에 저장하는 다운로드 대기열이다. 파일 전송을 위한 별도 중계 서버는 필요하지 않다.

화면 잠금이나 다른 앱 사용 중에도 전송할 수 있지만, 사용자가 Madeira를 강제 종료하면 iOS가 전송을 취소한다. 다운로드 완료와 압축 해제·게임 등록 완료도 구분해야 한다. 이 문서는 코드 및 공식 API 문서에 따른 설계 조사이며, 실제 Google 계정 인증과 iPhone 장시간 전송을 검증한 결과는 아니다.

## 기존 코드에서 활용할 부분

| 위치 | 확인한 구조와 적용 방향 |
| --- | --- |
| [SteamDownloadBackground.swift](../app/Madeira/SteamDownloadBackground.swift) | iOS 26 `BGContinuedProcessingTask`, 진행률, 알림, 만료 시 일시정지 처리. Drive의 압축 해제 같은 앱 내부 작업에 참고할 수 있다. |
| [GOGLibrary.swift](../app/Madeira/GOGLibrary.swift) | 설치 대기열, 설치 기록, 게임 등록 구조. 백그라운드 실행 시간이 끝나면 취소하고 복귀 시 재개한다. 시스템이 전송을 별도로 수행하는 구조는 아니다. |
| [GOGDownloader.swift](../app/Madeira/SwiftGOG/GOGDownloader.swift) | 임시 파일, 무결성 검사, 완료 기록, 설치 경로 검사. HTTP 세션은 `ephemeral`이다. |
| [ItchLibrary.swift](../app/Madeira/ItchLibrary.swift) | `ItchTransfer`에 파일 다운로드 delegate와 resume data 처리가 있다. 세션이 `.default`이고 메모리의 continuation에 의존하므로 설정 한 줄만 바꿔 앱 재시작 복구를 구현할 수는 없다. `ItchProgram`은 실행 파일 탐색의 참고 대상이다. |
| [ItchArchive.swift](../app/Madeira/SwiftItch/ItchArchive.swift) | ZIP64, 파일 단위 스트리밍 해제, CRC 검사, 경로 이탈·심볼릭 링크·대소문자 충돌 검사. ZIP 지원의 주요 재사용 대상이다. |
| [MadeiraApp.swift](../app/Madeira/MadeiraApp.swift) | SwiftUI 앱 시작 및 URL 라우팅. 현재 앱 소스에는 background URLSession 완료 이벤트를 받는 app delegate가 없어 추가해야 한다. |
| [Library.swift](../app/Madeira/Library.swift), [LibraryGridPage.swift](../app/Madeira/LibraryGridPage.swift), [SettingsPages.swift](../app/Madeira/SettingsPages.swift) | 소스별 설치 식별자, 탭, 상세 화면과 설정을 확장해야 한다. 기존 목록과 새 그리드 양쪽에 표시 경로가 있다. |

기존 스토어는 각자 모델과 다운로드 구현을 갖고 있다. 첫 구현에서는 Steam/GOG 전체를 공통 다운로드 프레임워크로 바꾸기보다 Drive 모듈을 추가하고, 필요한 압축 해제·경로 검사만 재사용하는 편이 변경 범위를 줄인다.

## 사용할 때의 흐름

확정한 사용자 요구는 **앱의 Google 로그인 버튼으로 접근 권한을 허용하고, 원본 Drive 폴더도 사용자가 직접 선택하는 것**이다. 특정 계정이나 개발자의 게임 폴더를 앱에 고정하지 않는다. 원본 경로 선택은 필수 흐름이고, 기기 내 설치 위치 선택은 별도의 확장 항목으로 구분한다.

1. 설정의 Google Drive 연결에서 “Google로 로그인”을 누른다. 시스템 인증 화면에서 계정을 선택하고 Drive 접근 권한을 허용한다.
2. 앱의 폴더 탐색 화면에서 게임 보관 폴더를 직접 선택한다. 현재 경로와 상위 폴더 이동을 표시하고 “이 폴더 사용”으로 확정한다. Drive 폴더 링크 입력도 보조 수단으로 제공한다.
3. Google Drive 탭에 해당 폴더의 ZIP 파일과 하위 게임 폴더를 표시한다.
4. 다운로드를 누르면 크기와 저장 공간을 확인하고 대기열에 넣는다.
5. ZIP은 내려받은 후 압축을 풀고, 게임 폴더는 상대 경로를 유지하며 파일을 받는다.
6. 실행 파일을 확인해 라이브러리에 등록한다. 여러 EXE가 있으면 사용자가 선택한다.

예를 들어 `Madeira Games/Game A.zip`과 `Madeira Games/Game B/`를 각각 한 게임 후보로 취급한다. 하위 폴더가 단순 분류용일 수도 있으므로 폴더 탐색과 “이 폴더 다운로드”를 제공하고, 모든 폴더를 자동으로 게임이라고 확정하지 않는다. 표지·실행 인자·작업 폴더는 처음에는 수동 보완할 수 있게 한다. 다운로드 성공만으로 게임의 실행 호환성이 보장되지는 않는다.

표시 경로와 폴더 ID를 함께 보관하되 재접속에는 계정 식별자와 폴더 ID를 사용한다. 연결 폴더 변경은 이후 목록과 새 다운로드에 적용하고, 이미 시작한 작업에는 원래의 소스와 대상 정보를 유지한다. 연결 해제와 폴더 재선택을 설정에서 제공한다.

기기 내 저장 위치까지 선택하게 확장할 경우에는 원본 Drive 경로와 구분해 표시한다. 앱 내부 설치 폴더를 기본값으로 하고, 로컬 외장 폴더는 기존 [ExternalDrives.swift](../app/Madeira/ExternalDrives.swift)의 폴더 선택·bookmark·Wine 드라이브 연결 구조를 검토한다. 백그라운드 수신 파일은 먼저 앱 내부에 보존하고, 최종 대상에 접근할 수 있을 때 이동·설치하는 설계가 적합하다. 외장 장치가 분리되면 다운로드를 잃지 않고 설치 대기로 남겨야 한다.

## Google 인증과 폴더 접근 권한

Google Cloud 프로젝트에서 Drive API와 OAuth 동의 화면을 설정하고 iOS용 OAuth client ID를 등록한다. Google Sign-In SDK가 인증 및 토큰 갱신을 담당하고, Drive REST 요청에 access token을 붙이는 구성을 우선 검토한다. `Info.plist`에는 client ID 및 역순 client ID 기반 URL scheme을, 앱에는 로그인 콜백 라우팅을 추가한다. 사이드로딩 시 바뀌는 bundle ID, URL scheme, Keychain 접근 조건은 실제 배포 IPA에서 먼저 확인해야 한다. [Google iOS 연동 설정](https://developers.google.com/identity/sign-in/ios/start-integrating)

Google 로그인은 SDK의 시스템 인증 흐름을 사용한다. GOG의 웹 로그인 화면을 그대로 복제해 Google OAuth를 임베디드 웹뷰로 처리하는 방식은 적합하지 않다. [Google OAuth 정책](https://developers.google.com/identity/protocols/oauth2/policies)

사용자가 앱에서 접근 권한을 허용하는 흐름은 SDK의 추가 권한 요청으로 구현할 수 있다. 실제 승인된 scope를 확인한 뒤 폴더 탐색을 열고, 거절한 경우에는 연결 전 상태를 유지한다. 앱에서 사용자 동의를 받는 것과 개발자가 OAuth client를 사전 등록하는 것은 각각 필요하다. [iOS 권한 요청과 사전 설정](https://developers.google.com/identity/sign-in/ios/api-access)

일반 사용자에게 OAuth client ID나 API key 입력을 요구하지 않는다. 개발자가 앱용 Google Cloud 프로젝트와 OAuth client를 설정하고, 사용자는 로그인·권한 허용·폴더 선택만 수행한다. 사용자 동의를 받더라도 앱의 OAuth 등록 및 공개 배포 검증 조건은 적용된다. [Google iOS client 설정](https://developers.google.com/identity/sign-in/ios/start-integrating)

| 접근 방식 | 이 기능에 대한 판단 |
| --- | --- |
| `drive.readonly` | 기존 게임 폴더와 그 안의 파일을 읽는 기능에 맞는다. 다만 권한 자체는 계정의 Drive 전체 읽기·다운로드이며, 앱에서 선택 폴더만 조회하는 것과 OAuth 권한 범위는 다르다. |
| `drive.file`와 파일 선택 | 사용자가 앱에 허용한 개별 파일을 다루는 좁은 권한이다. ZIP 파일 선택에는 대안이지만, 폴더 하나 선택으로 기존·미래의 모든 하위 파일 접근까지 허용된다고 전제하면 안 된다. 폴더 라이브러리 요구를 충족하는지 별도 검증이 필요하다. |
| 공개 공유 폴더와 API key | 공개 폴더 목록 조회가 가능하다. 개인 게임 파일을 공개해야 하는 방식은 기본안으로 삼지 않고, 사용자가 이미 공개한 소스를 위한 별도 옵션으로 둔다. |

`drive.readonly`는 Google의 restricted scope이다. 공개 서비스는 해당 권한의 허용 용도와 검증 요건을 충족해야 하며, Madeira가 승인될지는 별도 확인 대상이다. 서버에 restricted 데이터를 저장하거나 전송하면 보안 평가 조건도 생길 수 있으므로, 초기안은 기기와 Google 사이에서 직접 처리한다. [Drive 권한 및 검증 조건](https://developers.google.com/workspace/drive/api/guides/api-specific-auth)

개인 계정으로 먼저 시험할 수 있다. 다만 외부 사용자용 OAuth 앱을 `Testing` 상태로 두고 Drive 권한을 요청하면 refresh token의 7일 만료 조건이 적용되므로, 장기 사용에는 재인증 UX와 배포 상태 검토가 필요하다. [OAuth 토큰 만료 조건](https://developers.google.com/identity/protocols/oauth2#expiration)

## ZIP과 게임 폴더 다운로드

| 항목 | ZIP | 게임 폴더 |
| --- | --- | --- |
| 전송 대상 | 일반적으로 큰 파일 하나 | 하위 폴더를 탐색한 뒤 각 파일 |
| 기존 코드 활용 | ZIP64 해제 및 실행 파일 탐색 | 실행 파일 탐색, 경로 검사, 설치 기록 |
| 주요 장점 | 요청 수가 적어 대기열·백그라운드 처리가 단순함 | 압축 해제 없이 원래 구조를 설치할 수 있음 |
| 주요 비용 | 압축 파일과 해제된 파일을 함께 둘 공간, 해제 시간 | 많은 API 요청, 파일별 상태 관리, 원격 폴더 변경 감지 |

목록 조회는 `files.list`의 `q = '<folderId>' in parents and trashed = false`를 사용하고 `nextPageToken`을 끝까지 처리한다. 이 조건은 직계 자식만 반환하므로 게임 폴더는 앱이 하위 폴더를 순회해야 한다. ZIP은 일반 바이너리 파일로 받고, 게임 폴더는 파일별 전송 목록으로 펼치는 설계다. [Drive 파일·폴더 검색](https://developers.google.com/workspace/drive/api/guides/search-files)

파일 내용은 `GET /drive/v3/files/{fileId}?alt=media`로 받는다. 다운로드 가능 여부인 `capabilities.canDownload`를 확인하고, 재전송 범위가 필요하면 HTTP `Range`를 사용한다. 웹 다운로드 확인 화면이나 공유 링크 HTML을 파싱하는 방식에 의존할 필요가 없다. [Drive 다운로드와 부분 다운로드](https://developers.google.com/workspace/drive/api/guides/manage-downloads)

폴더 전송은 시작 시 계정·루트 폴더·파일 ID·상대 경로·크기·변경 버전·체크섬을 기록한다. 파일명만으로 식별하지 않고 중복 이름 및 Windows에서 같은 경로로 취급될 이름을 검사한다. 완료 파일의 체크섬을 확인하고, 중간에 원격 파일이 바뀌면 기존 조각과 합치지 않는다. `version`, `modifiedTime`, `size`, `md5Checksum` 등의 메타데이터를 활용할 수 있다. 이는 앱이 구현할 검증 절차이며 폴더 전체의 원자적 스냅샷을 보장하는 API는 아니다. [Drive 파일 메타데이터](https://developers.google.com/workspace/drive/api/reference/rest/v3/files)

첫 범위는 내 Drive와 해당 계정에 직접 공유된 폴더로 한다. Workspace 공유 드라이브를 추가하면 `supportsAllDrives`, `includeItemsFromAllDrives`, `driveId` 등의 처리가 필요하다. 링크의 `resourceKey`도 보존해야 한다. 바로가기는 초기에는 미지원 표시하고, 후속 지원 시 루트 밖 이동·순환 참조를 검사한다. [공유 드라이브](https://developers.google.com/workspace/drive/api/guides/enable-shareddrives), [Resource key](https://developers.google.com/workspace/drive/api/guides/resource-keys)

## 대용량 백그라운드 전송 설계

전송에는 고정 식별자의 `URLSessionConfiguration.background(withIdentifier:)`와 `URLSessionDownloadTask`를 사용한다. 시작할 때 세션을 다시 연결하고 `getAllTasks` 결과를 디스크의 대기열과 대조한다. `@UIApplicationDelegateAdaptor`를 통해 background session 이벤트를 받고, 다운로드 delegate에서 임시 파일을 영구 저장 위치로 이동한 뒤 상태를 기록한다. 메모리의 Swift `Task`나 화면 수명에 완료 처리를 의존시키지 않는다. [Apple 백그라운드 다운로드](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)

| 상황 | 지원 목표와 제약 |
| --- | --- |
| 홈 화면 이동·다른 앱 사용·화면 잠금 | OS가 전송을 이어갈 수 있다. 네트워크·전력·OS 스케줄링에 따라 지연될 수 있다. |
| OS가 메모리 회수를 위해 앱 종료 | 같은 세션 ID로 다시 연결하여 진행 중 전송과 완료 이벤트를 복구한다. |
| 사용자가 앱 전환 화면에서 강제 종료 | OS가 전송을 취소한다. 사용자가 다시 실행한 뒤 대기열과 저장된 부분을 확인해 재개한다. 마지막 파일의 모든 수신 바이트가 보존된다고 보장하지 않는다. |
| ZIP 전송 완료 | 짧은 완료 콜백에서는 파일 이동과 상태 저장을 끝낸다. 압축 해제 완료를 곧바로 보장하지 않는다. |
| 인증 만료·권한 회수 | 갱신·재시도하거나 “계정 재연결 필요” 상태를 저장한다. 잠금 중 갱신 실패 시 복귀 후 이어간다. |

앱 강제 종료와 OS 종료의 차이는 iOS의 공식 동작이다. [Apple background session 수명](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))

대기열은 예를 들어 `queued → downloading → downloaded → verifying → extracting → ready`로 나누고, `paused`, `retryWaiting`, `needsSignIn`, `failed`도 저장한다. task identifier와 자체 job ID를 연결하고, 계정 전환·로그아웃 시 다른 계정의 작업을 이어받지 않도록 한다. 대용량 수치는 `Int64` 또는 `UInt64`로 처리하며, 본문 전체를 `Data`로 읽지 않는다.

백그라운드에서 파일 하나가 끝날 때마다 다음 하나만 생성하면 iOS의 재기동 제한으로 지연이 누적될 수 있다. 사용자 화면에서 작업 목록을 먼저 만들고 적당한 묶음으로 등록한다. 파일이 매우 많은 게임은 ZIP 보관을 권장하고, 실제 동시 전송 수와 묶음 크기는 기기 테스트로 정한다. [Apple 세션 사용 지침](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background#Use-background-sessions-efficiently)

### 이어받기와 토큰 만료

`resumeData`는 가능한 경우에만 사용한다. Apple도 모든 다운로드의 재개를 보장하지 않으며, 백그라운드 세션의 네트워크 복구 기능과 사용자 일시정지는 구분해야 한다. [Apple 다운로드 재개](https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads)

특히 등록 후 오래 대기한 요청이나 재연결 요청에는 만료된 access token이 들어 있을 수 있다. Google SDK의 `refreshTokensIfNeeded`를 호출하는 것은 앱의 역할이며, 시스템 전송 프로세스가 Google SDK를 대신 실행해 토큰을 갱신하지 않는다. 401 응답은 새 토큰으로 요청을 재생성하고 재개해야 한다. [Google 토큰 갱신](https://developers.google.com/identity/sign-in/ios/api-access)

실기기 PoC에서는 인증 헤더가 있는 `resumeData`의 동작을 우선 확인한다. 오래된 인증 정보로 재개가 실패하면 opaque resume data를 수정하지 않고, 영구 보관한 바이트 구간과 새 `Range` 요청을 사용하는 대안을 검증한다. `206`과 `Content-Range`를 확인하고, `200` 응답을 부분 파일 뒤에 잘못 붙이지 않는다. `416`이나 원격 파일 변경은 메타데이터를 다시 확인한다. 구간별 작업은 완료 조각을 보존할 수 있지만, 요청 수와 임시 공간이 증가하므로 무조건 작은 조각으로 분할하지 않는다.

잠긴 기기에서도 토큰과 다운로드 상태를 사용할 수 있는지는 SDK의 Keychain 접근 속성과 로컬 파일 보호 수준까지 포함해 확인한다. 기존 GOG token store의 `WhenUnlockedThisDeviceOnly` 설정을 그대로 복제하면 잠금 중 인증 복구 요구에 맞지 않을 수 있다.

### 압축 해제와 저장 공간

ZIP 해제는 앱의 CPU 작업이다. 사용자가 화면에서 시작한 설치 작업에는 iOS 26 `BGContinuedProcessingTask`를 검토하되, OS가 중단할 수 있으므로 “다운로드 완료·설치 대기” 상태를 유지한다. 백그라운드 전송 완료 시점에 새 continued-processing 작업을 항상 시작할 수 있다고 가정하지 않는다. [Apple continued processing](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)

기존 `ItchArchive.unpack`는 시작 시 staging 폴더를 다시 만들고, 파일별 해제 체크포인트를 저장하지 않는다. 첫 구현에서는 ZIP 원본을 유지해 해제 재시작을 허용하고, 중단 확인 및 필요하면 파일별 체크포인트를 보강한다. 기존 설치 교체도 실패 시 복구할 수 있게 준비한 폴더와 이전 설치의 보존 순서를 설계한다.

ZIP 설치의 최대 사용 공간은 압축 파일 + 해제한 새 파일 + 보존 중인 이전 설치 + 전송 임시 파일을 고려해야 한다. 예를 들어 20 GB ZIP이 50 GB로 풀리면 새 설치만으로 약 70 GB와 여유 공간이 필요하다. 다운로드 전에는 압축 크기를, 해제 전에는 ZIP 디렉터리의 해제 크기를 확인하고 작업 중에도 공간 부족을 처리한다. 암호화·분할 ZIP과 기존 해제기가 지원하지 않는 압축 방식은 명확히 표시한다.

## 필요한 신규 모듈과 연결 지점

다음 이름은 구현안이며 아직 생성된 앱 소스가 아니다.

| 구성 | 역할 |
| --- | --- |
| `DriveAuth.swift` | 계정 연결·연결 해제, 추가 권한, 유효한 토큰 획득 |
| `DriveAPI.swift` | 폴더·파일 목록, 페이지 처리, 메타데이터, 다운로드 요청 |
| `DriveDownloadManager.swift` | background session delegate, task 복원, 재시도, 일시정지, 진행률 |
| `DriveDownloadStore.swift` | 계정별 작업·파일 목록·완료 구간·설치 상태 영속화 |
| `DriveInstaller.swift` | ZIP 해제, 폴더 완성 검증, 설치 경로·공간 검사, EXE 선택 |
| `DriveLibrary.swift`, `DriveGames.swift` | 연결 폴더, 라이브러리 항목, 다운로드·설정 화면 |

기존 `MadeiraApp.swift`, `Info.plist`, `project.pbxproj`에 인증과 앱 수명 연결을 추가한다. `LibraryEntry`에는 이전 저장 파일을 계속 읽을 수 있는 optional Drive 식별자와 등록 경로를 추가하고, `LibraryStoreTab`, 기존 목록, 새 그리드, 설정 페이지 및 기존 긴 설정 화면을 모두 연결한다. 다운로드·복구 자체는 Wine 실행이나 JIT 활성화가 없어도 수행하도록 분리한다.

## 구현 순서와 검증 기준

1. **인증과 대용량 전송 PoC**: 실제 사이드로딩 IPA에서 계정 연결, 비공개 폴더 조회, 큰 ZIP 전송, 화면 잠금, 토큰 만료 후 재요청, 앱 재시작 복구를 확인한다. 이 단계가 전체 UI 구현보다 먼저다.
2. **ZIP 설치 경로**: 폴더 연결, ZIP 목록, 다운로드·일시정지·취소, 공간 확인, 안전한 해제, EXE 선택, 라이브러리 등록을 만든다.
3. **게임 폴더 경로**: 재귀 목록 및 페이지 처리, 다수 파일 대기열, 파일별 검증, 완료 파일 재사용, 원격 변경·동일 이름 충돌 처리를 추가한다. 두 입력 형태를 모두 처리해야 이번 사용자 요구가 충족된다.
4. **복구 및 배포 검증**: 서명 갱신 후 로그인 복원, 연결 해제, 통신 오류, 손상된 ZIP, 저장 공간 부족, 기존 라이브러리 호환성, Google 권한 검증 조건을 확인한다.

실기기에서 최소한 다음 경우를 확인한다. 디버거가 붙은 실행만으로 백그라운드 동작을 판단하지 않는다.

| 테스트 | 확인할 결과 |
| --- | --- |
| 4 GB를 넘는 ZIP64와 장시간 전송 | 크기 오버플로·전체 메모리 적재 없이 완료 및 체크섬 일치 |
| 화면 잠금, Wi-Fi 단절과 재연결 | OS 전송 및 작업 상태 복구, 중복 설치 없음 |
| OS 종료와 사용자 강제 종료를 각각 시험 | 전자는 session 복원, 후자는 재실행 후 복구 가능한 범위부터 재개 |
| 토큰 만료 후 새 요청, 권한 회수, 계정 전환 | 새 토큰 사용, 불가능하면 재연결 안내, 계정 데이터 혼용 없음 |
| 파일 수가 많고 여러 페이지·깊은 하위 폴더가 있는 게임 | 누락 없이 상대 경로 보존, 요청 수 제어 |
| 다운로드 중 Drive 파일 변경 | 다른 버전의 바이트를 합치지 않음 |
| ZIP 해제 중 중단·디스크 부족·손상·경로 이탈 | 기존 설치 보존, 실패 상태 복원, 라이브러리에 불완전 게임 등록 없음 |
| EXE가 여러 개이거나 없음 | 실행 파일 선택 또는 다운로드 완료 후 수동 등록 안내 |

## 사용량과 오류 처리

403 응답은 다운로드 금지·권한 부족과 사용량 제한을 오류 reason으로 구분한다. 429 및 일시적 서버 오류에는 지수 백오프를 적용하고, 권한 부족을 무한 재시도하지 않는다. [Drive 오류 처리](https://developers.google.com/workspace/drive/api/guides/handle-errors)

2026-11-14 확인한 문서에는 2026-05-01 이후 신규 프로젝트에 새 quota 체계가 적용되며, 프로젝트당 일일 다운로드 전송량 항목이 1 TB로 기재되어 있다. 기존 사용 프로젝트에는 이전 quota가 유지될 수 있고, 초과 과금 전환에 관한 별도 공지도 안내한다. 따라서 배포 대상 Cloud 프로젝트의 실제 quota와 최신 과금 적용 일정을 출시 전에 확인해야 하며, 무제한 다운로드나 모든 사용자에게 항상 무료라는 전제는 두지 않는다. 개인 다운로드와 여러 사용자가 하나의 OAuth 프로젝트를 공유하는 배포는 사용량 조건이 다르다. [Drive 사용량 제한](https://developers.google.com/workspace/drive/api/guides/limits)
