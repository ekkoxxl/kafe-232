# CI ve onaylı özel ağ yayını

Bu proje klasik ASP.NET MVC 5 / .NET Framework 4.8.1 uygulamasıdır. CI, NuGet restore, Release derlemesi, Razor doğrulaması ve yayın paketi üretir. Henüz bulunmayan EF6/EDMX entegrasyonunu veya kafe işlevlerini test etmiş sayılmaz.

## Günlük ekip akışı

1. Geliştirici kendi dalına commit/push yapar ve `main` için pull request açar.
2. `CI / Build and package` NuGet restore, Release/Razor derlemesi, yayın paketi ve dağıtım güvenlik kontrollerini çalıştırır. PR incelemesi ve başarılı CI, `main` kurallarıyla zorunludur.
3. Yönetici PR'ı birleştirir. `main` push CI çalışması yeniden paket üretir; PR artifact'ı yayınlanmaz.
4. Başarılı `main` CI sonrasında `Deploy demo` başlar ve `demo` environment onayını bekler. Yayın onayı Orçun'dadır.
5. Onaylanan GitHub-hosted Ubuntu runner, kısa ömürlü Tailscale OIDC kimliğiyle `tag:kafe-ci` olarak ağa katılır. Bu etiket yalnız sunucunun TCP 5986 dağıtım portuna erişir.
6. İstemci özgün GitHub artifact ZIP'inin boyutunu, GitHub SHA256 digest'ini ve manifest'ini kontrol eder. TLS sertifikası doğrulanmış WinRM/JEA bağlantısından parça parça yükler.
7. Sunucu bağımsız GitHub metadata doğrulaması yapar: repository/owner kimlikleri, sabit CI workflow'u, başarılı `push`, `main`, güncel commit, artifact kimliği ve digest eşleşmelidir. Eski bir `main` sürümü bu yolla yeniden yayınlanamaz.
8. Dosya envanteri doğrulandıktan sonra yeni IIS sürümüne geçilir. Kimlikli HTTP 200 ve anonim HTTP 401 kontrol edilir. Hata halinde eski IIS yolu geri yüklenir. Tailscale action iş sonunda geçici bağlantıyı kapatır.

Kurulumun tamamlanmış sayılması için environment değişkenleri, Tailscale trust/erişim politikası ve GitHub-hosted runner üzerinden gerçek onaylı yayın ayrıca doğrulanmalıdır. Dosyaların repoda bulunması bu bağlantıların kurulmuş olduğu anlamına gelmez.

## Sunucu ve yetkiler

- Derleme GitHub-hosted Windows ortamında yapılır. Genel uygulama reposuna bağlı bir self-hosted runner sunucuya kurulmaz.
- Uzak yayın `deploy.yml` ile yürütülür; aşağıdaki yerel komutlar yönetici için elle yayın/geri dönüş yoludur.
- Sunucu yalnız yönetici tarafından hazırlanır. Geliştiricilere RDP/admin yetkisi verilmesi gerekmez.
- `KafeDemo` sitesi ve aynı adlı uygulama havuzu önceden hazırlanmış olmalıdır. Bağlamalar `127.0.0.1:8080` ve Tailscale `100.126.247.75:8080` adresleridir. Ekip bağlantısı `http://100.126.247.75:8080/` üzerinden özel ağda yapılır. Genel IP/alan adı veya port yönlendirmesi gerekmez.
- Windows Authentication açık, Anonymous Authentication kapalı kalır. Havuz `ApplicationPoolIdentity` ve .NET `v4.0` kullanır; uygulama Administrator/sysadmin olarak çalıştırılmaz.
- Başlangıç klasörü `C:\KafeDemo\releases\bootstrap` boş olabilir. İlk başarılı yayından önce geri dönebilecek doğrulanmış uygulama sürümü yoktur.

`kafepublisher`, yönetici olmayan ve yalnız `KafeDeploy` JEA endpoint'ine bağlanan yerel servis hesabıdır. `kafesmoke`, yalnız IIS sağlık kontrolünde kullanılır. İkisi de normal geliştirici hesabı değildir; console/RDP girişi engellenir. JEA, kısa ömürlü sanal yönetici kimliğiyle yalnız beş işlemi sunar: sürüm okuma, yükleme açma, parça gönderme, doğrulanmış paketi yayınlama ve önceki sürüme dönme. Genel PowerShell, dosya okuma/yazma veya süreç çalıştırma komutları dışarıya açılmaz.

Endpoint yalnız `https://100.126.247.75:5986/wsman` üzerinden kullanılır. İstemci sunucunun public PEM sertifikasına güvenir; sertifika/hostname doğrulaması kapatılmaz. Firewall yalnız Tailscale arayüzünü ve özel ağ adreslerini kabul eder. Mevcut HTTP WinRM listener'ı varsa bu kurulum onu değiştirmez; dağıtım fonksiyonları HTTP bağlantısını ayrıca reddeder.

## İlk uzak yayın kurulumu — yalnız yönetici

`infra/remote-deploy/Install-KafeRemoteDeploy.ps1`, bu sunucunun sabit IP/host/site bilgilerine göre hazırlanmıştır. IIS ve Tailscale hazır olduktan sonra incelenmiş temiz kaynaktan, yükseltilmiş Windows PowerShell 5.1 ile bir kez çalıştırılır:

```powershell
.\infra\remote-deploy\Install-KafeRemoteDeploy.ps1
```

Bu makinede hesaplar, sertifika ve endpoint zaten oluşturulduysa installer tekrar çalıştırılmaz. Yarım kalan endpoint kaydı için `Complete-KafeRemoteDeploy.ps1` mevcut korumalı yapılandırmayı kullanır; hesap/parola oluşturmaz. Gerçek bağlantı testinin yerini tutmaz ve yapılandırmayı yeniden kaydederken WinRM servisini yeniden başlatır.

Korunan sunucu dosyaları:

| Konum | İçerik |
| --- | --- |
| `C:\KafeDemo\admin-tools` | Yönetici tarafından yüklenmiş güvenilir IIS betikleri; artifact içinden çalıştırılmaz |
| `C:\Program Files\WindowsPowerShell\Modules\Kafe.Deployment\1.0.0` | İncelenmiş JEA modülü ve role capability |
| `C:\KafeDemo\state\remote-deploy.json` | Sunucu kimliği ve endpoint ayarları |
| `C:\KafeDemo\state\winrm-ca.pem` | Public TLS sertifikası; secret değildir |
| `C:\KafeDemo\secrets\publisher-credential.clixml` | Kurulumu yapan Windows kullanıcısının DPAPI ile koruduğu publisher credential |
| `C:\KafeDemo\secrets\smoke-password.bin` | LocalMachine DPAPI ile korunan smoke parolası; dosya ACL'si ayrıca zorunludur |
| `C:\KafeDemo\state\remote-deploy-audit.jsonl` | Sınırlı hata kodları, kimlikler ve güvenli hata metadata kaydı |
| `C:\KafeDemo\jea-transcripts` | Yöneticiye özel oturum kayıtları; herkese açık artifact olarak yüklenmez |

State, secrets, yönetim betikleri ve staging alanına yalnız SYSTEM/Administrators yazabilmelidir. Publisher, modülde yalnız okuma/çalıştırma yetkisine sahiptir. Repo değişikliği bu yönetici kodlarını sunucuda otomatik değiştirmez: modül/betik güncellemesi yönetici incelemesi ve yeniden bağlantı testinden sonra ayrıca uygulanır.

### Tailscale bağlantısı

1. Access controls politikasına `tag:kafe-ci` sahipliğini yalnız yöneticiye verecek `tagOwners` kaydı ekleyin. Mevcut yönetici erişimini ve üyelerin TCP 8080 uygulama erişimini koruyun. CI etiketine yalnız `100.126.247.75` hedefinde `tcp:5986` grant verin; genel `*` izin vermeyin. Politika testlerinde CI için 3389, 1433 ve 8080 erişiminin reddedildiğini kontrol edin. Repodaki `infra/remote-deploy/tailscale-policy.example.json` şablonunda `REPLACE_WITH_OWNER_TAILSCALE_EMAIL` alanlarını yöneticinin Tailscale giriş e-postasıyla değiştirin ve mevcut bulut politikasıyla karşılaştırın. Sunucuda hazırlanmış `Kafe_Tailscale_CD_Erisim.json` dosyası bu alanlar doldurulmuş yerel kopyadır.
2. Tailscale admin → **Trust credentials → Credential → OpenID Connect** açın. Issuer GitHub Actions (`https://token.actions.githubusercontent.com`) olsun.
3. Subject değerini tam olarak yazın: `repo:OrcunUcuncu@68338579/kafe-232@1431509368:environment:demo`.
4. Custom claims alanlarını aşağıdaki gibi eşitleyin. Wildcard kullanmayın.

| Claim | Değer |
| --- | --- |
| `repository_id` | `1431509368` |
| `repository_owner_id` | `68338579` |
| `environment` | `demo` |
| `ref` | `refs/heads/main` |
| `workflow_ref` | `OrcunUcuncu/kafe-232/.github/workflows/deploy.yml@refs/heads/main` |
| `runner_environment` | `github-hosted` |

5. Yalnız **Auth Keys / Write** (`auth_keys`) scope ve yalnız `tag:kafe-ci` seçin. Credential oluşturunca **Client ID** ve **Audience** değerlerini alın. Bunlar public tanımlayıcılardır; OAuth client secret gerekmez.

Subject, bu reponun yeni immutable OIDC formatını kullanır. Repo adı/owner/kimlik veya environment değişirse trust eşleşmesi yeniden incelenir. Kaynaklar: [Tailscale workload identity federation](https://tailscale.com/docs/features/workload-identity-federation), [GitHub immutable subject claims](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims).

### GitHub `demo` environment

Repository → **Settings → Environments → demo** içinde required reviewer yalnız Orçun, deployment branch yalnız `main` olmalıdır. **Prevent self-review** kapalı olmalıdır ki yönetici kendi değişikliğinin yayınını da onaylayabilsin. Environment korumalarını yönetici bypass seçeneğiyle atlamayın.

Environment **Variables**:

| Ad | Değer |
| --- | --- |
| `TS_CLIENT_ID` | Tailscale'in verdiği Client ID |
| `TS_AUDIENCE` | Tailscale'in verdiği Audience |
| `KAFE_DEPLOY_HOST` | `100.126.247.75` |
| `KAFE_DEPLOY_PORT` | `5986` |
| `KAFE_DEPLOY_USER` | `WIN-M7LSG103N98\kafepublisher` |
| `KAFE_WINRM_CA_PEM` | Public `winrm-ca.pem` dosyasının BEGIN/END satırları dahil tamamı |

Environment **Secrets**: yalnız `KAFE_DEPLOY_PASSWORD`, oluşturulan **kafepublisher** hesabının parolasıdır. Administrator parolası kullanılmaz. Kurulumu yapan Windows hesabında parolayı terminale yazdırmadan panoya almak için:

```powershell
$publisherCredential = Import-Clixml -LiteralPath 'C:\KafeDemo\secrets\publisher-credential.clixml'
Set-Clipboard -Value $publisherCredential.GetNetworkCredential().Password
$publisherCredential = $null
```

Secret'ı GitHub'a yapıştırdıktan sonra `Set-Clipboard -Value ''` çalıştırın. Parola sohbet, commit veya loglara eklenmez. `GH_TOKEN` workflow'un kısa ömürlü `github.token` değeridir; ayrıca PAT oluşturulmaz. Gerekli Actions izinleri workflow içinde `actions: read`, `contents: read`, `id-token: write` olarak tanımlıdır.

### İlk yayın ve tekrar deneme

Bu PR `main`e birleştirildikten sonra yeni `main` CI sonucunu bekleyin. `Deploy demo` içindeki **Review deployments** üzerinden commit'i kontrol edip `demo` için **Approve and deploy** seçin. Başarılı iş, beklenen commit ile kimlikli 200/anonim 401 sonucunu bildirir. Ardından özel ağdaki tarayıcıdan uygulamayı açın.

Ayarlardan biri eksikken ilk iş başarısız olmuşsa, güncel `main` push CI run ID'sini Actions adresinden alın. **Actions → Deploy demo → Run workflow**, branch `main`, `ci_run_id` o sayısal ID olacak şekilde yeniden başlatın. Yalnız `workflow_dispatch` CI çalışması yeterli değildir; seçilen CI'nin event'i `push` olmalıdır. Daha yeni `main` commit'i varsa önce onun CI'si başarılı olmalıdır.

GitHub metadata okunamazsa, rate limit dolarsa, artifact silinmiş/7 günlük saklama süresi dolmuşsa veya digest yoksa işlem kapalı kalır. Yeni başarılı `main` paketi ya da geçici API sorununun çözülmesi gerekir. Sunucunun metadata sorguları public REST API kotasını kullanır; tekrarlı hata denemeleri kotayı tüketebilir. İstemci genel hata bildirirse yönetici audit dosyasındaki güvenli hata kodu/type/satır bilgisini inceler; token/parola veya ham remoting istekleri paylaşılmaz.

### Kimlik ve sertifika bakımı

Publisher parolası yönetici tarafından değiştirilirse GitHub `demo` secret'ı ve korumalı CLIXML yedeği de birlikte güncellenir; eski secret ile dağıtım çalışmaz. Smoke hesabının parolası değişirse `smoke-password.bin` aynı entropy ile yeniden üretilmelidir. Installer bunun için tekrar çalıştırılmaz. Hesaplar insan oturumu için kullanılmaz.

TLS sertifikası iki yıl süreyle oluşturulur. Süre dolmadan yeni SAN/host sertifikası üretilip WinRM listener thumbprint'i, korumalı config ve GitHub public PEM değeri birlikte güncellenir; bağlantı ve yanlış sertifika reddi yeniden test edilir. Acil dağıtımı kapatmak için yönetici GitHub environment secret'ını kaldırabilir, Tailscale trust credential'ını iptal edebilir veya publisher hesabını devre dışı bırakabilir; mevcut IIS uygulama sürümü çalışmaya devam eder.

## Yöneticinin onayladığı paketi alma

1. GitHub Actions'ta doğru uygulama reposunun CI çalışmasını açın.
2. Yayın adayı için `main` dalındaki başarılı çalışmayı ve 40 karakterlik commit SHA'sını kontrol edin. Bir PR/fork çalışmasını veya başka bir kişinin gönderdiği ZIP'i yayın adayı olarak kullanmayın.
3. O çalışmanın yayın artifact'ını indirin ve sunucuda ayrı bir geçici klasöre çıkarın. Paket kökünde `Web.config`, `bin`, `Views` ve `deployment-manifest.json` bulunmalıdır.
4. Aşağıdaki komutlarda `C:\OnaylananPaket` ve `<onaylanan-40-karakterlik-sha>` alanlarını gerçek değerlerle değiştirin. Manifest etiketleri ve SHA256 envanteri paketin bozulmasını tespit eder; tek başına bir dijital imza veya GitHub kaynağının kanıtı değildir. Kaynağın ve onaylanan commit'in yukarıdaki adımla kontrolü gerekir.

## Önce paketi doğrulama

Yükseltilmiş yetki veya IIS değişikliği gerektirmez:

```powershell
.\scripts\Deploy-Iis.ps1 -PackageDirectory 'C:\OnaylananPaket' `
  -ExpectedCommitSha '<onaylanan-40-karakterlik-sha>' -ValidateOnly
```

`-WhatIf` de dosyaları doğrular, ardından yapılacak işlemi bildirir; IIS'e dosya kopyalamaz veya siteyi değiştirmez.

Manifest'te `sourceDirty` ve `validationOnly` açık boolean değerler olmalıdır. Her ikisi de `false` olmayan paket yayınlanamaz. `Build-Package.ps1 -AllowDirtySourceForValidation` ile yerel doğrulama için hazırlanmış bir paket, `-ValidateOnly` kontrolünde incelenebilir ve `Deployable=False` döndürür; gerçek yayın ve `-WhatIf` bu paketi reddeder. Manifest commit etiketi, değiştirilmiş yerel kaynakların temiz bir commit'e aitmiş gibi gösterilmesi için kullanılamaz.

## IIS yayını

Sunucuda yönetici olarak **Windows PowerShell 5.1** (`powershell.exe`) açın. PowerShell 7 yerine 5.1, Windows'un IIS WebAdministration modülü için kullanılır.

```powershell
.\scripts\Deploy-Iis.ps1 -PackageDirectory 'C:\OnaylananPaket' `
  -ExpectedCommitSha '<onaylanan-40-karakterlik-sha>'
```

Betik şunları yapar:

1. Repository (`OrcunUcuncu/kafe-232`), framework (`net481`), onaylanan commit, eksiksiz dosya envanteri, boyut ve SHA256 özetlerini doğrular. Eklenmiş/eksilmiş dosyaları, yol taşmasını, junction/symlink'leri ve veritabanı/anahtar dosyalarını reddeder.
2. Aynı anda ikinci yayın veya geri dönüşe izin vermeyen dosya kilidi alır.
3. Paketi yeni bir `C:\KafeDemo\releases\<sürüm>` klasörüne kopyalar. Önceki sürümleri silmez. Uygulama havuzuna kod üzerinde yalnız okuma/çalıştırma izni verir.
4. IIS'in fiziksel yolunu yeni sürüme geçirir ve yalnız bu siteye ayrılmış havuzu yeniden başlatır.
5. Smoke adresinin seçilen sitenin açıkça tanımlı loopback bağlamasıyla eşleştiğini doğrular. Yerel elle yayında mevcut Windows kullanıcısıyla, uzak yayında ayrı `kafesmoke` credential'ıyla HTTP 200; anonim istekle HTTP 401 bekler. `-HealthCheckCredential` verildiğinde yalnız bu hesabın SID'sine seçilen sürüm klasöründe okuma/çalıştırma izni eklenir; Windows Authentication'ın NTFS kontrolü için gereklidir. Hesaba yazma yetkisi verilmez. Bu basit kontrol uygulamanın tüm iş kurallarını test etmez. Kontrol hesabı ayrıca sitenin erişim listesinde izinli olmalıdır.
6. Kontrol başarılıysa `C:\KafeDemo\deployment-state.json` kaydını atomik olarak günceller. Başarısızsa eski fiziksel yolu geri yükler ve işlemi başarısız bildirir. İlk yayında eski yol boş bootstrap olabilir; bunun geri yüklenmesi çalışan bir önceki uygulama bulunduğu anlamına gelmez.

Sunucu yöneticisi `C:\KafeDemo` kökünün ve durum/kilit dosyalarının yalnız SYSTEM/Administrators tarafından yazılabildiğini korumalıdır. Uygulama havuzu bu dosyalara yazamamalıdır. Gelecekte dosya yükleme/log ihtiyacı çıkarsa kod klasörüne yazma açmak yerine repo dışı ayrı veri klasörü planlanır.

## Önceki uygulama sürümüne dönüş

Durum dosyasındaki `previousRelease.commitSha` değerini kontrol edin ve geri dönülecek SHA'yı açıkça verin:

```powershell
.\scripts\Rollback-Iis.ps1 -ExpectedCommitSha '<onceki-40-karakterlik-sha>' -ValidateOnly
.\scripts\Rollback-Iis.ps1 -ExpectedCommitSha '<onceki-40-karakterlik-sha>'
```

Geri dönüş de paket bütünlüğünü ve HTTP 200/401 kontrollerini çalıştırır. Mevcut IIS yolu kayıtlı durumla uyuşmuyorsa betik durur; beklenmeyen bir site değişikliğinin üzerine yazmaz. İlk başarılı yayında önceki doğrulanmış uygulama olmadığı için normal geri dönüş yapılamaz. Yayınlar ve geri dönüşler eski sürüm klasörlerini silmez.

## Veritabanı ayrı yönetilir

Bu betikler SQL bağlantısı açmaz; veritabanı oluşturmaz, migration/seed/reset/restore veya `CREATE`, `DROP`, `TRUNCATE` çalıştırmaz. Repodaki mevcut SQL dosyaları her yayında tekrar yürütülmez. Kod sürümüne dönüş, veritabanı şemasını geri almaz. EF Database First şema değişikliği, gerçek EDMX güncellemesi, test ve yedek/geri dönüş planı ayrı onaylı iştir.

Windows kullanıcılarının uygulamadaki `Employee.WindowsLogin` eşlemesi de yayın betiğinin görevi değildir. Henüz olmayan Employee/Manager veya başka bir entity/veri bu süreçte oluşturulmaz.
