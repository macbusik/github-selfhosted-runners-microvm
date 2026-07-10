# Status, checklista i ocena compliance (2026-07-06)

> **UPDATE 2026-07-09 (wieczór):** sekcja 3 jest już historyczna - AWS dopiął
> rollout control-plane API. Zweryfikowane na żywo: `list-microvm-images`,
> `get-microvm-image`, **`create-microvm-image`**, `terraform import` i
> `delete-microvm-image` działają przez CLI/CloudControl w `us-east-1`.
> Obraz `gh-runner-microvm-sample-cicd-repo` utworzony przez CLI z terraformową
> rolą build i zaimportowany do stanu - `terraform plan` = "No changes".
> Nowe ustalenia z tej sesji:
> - `AWS_REGION` jest teraz **zarezerwowanym** kluczem env (API go odrzuca;
>   3 dni wcześniej konsola go przyjmowała - patrz punkt 11 niżej, już
>   nieaktualny w tej formie). `hook_server.py` używa fallbacku
>   `MICROVM_AWS_REGION`.
> - Przy podanym porcie hooków API wymaga jawnego `ENABLED` na >= 1 hooku -
>   prawdopodobna przyczyna, dla której konsolowy obraz `gh-runner` nigdy nie
>   dostał `/run` (MicroVM z 22:11 wisiał RUNNING bez rejestracji runnera).
> - `baseImageVersion` "0" jest normalizowane do "0.0" - tfvars musi mieć
>   formę znormalizowaną, inaczej plan po imporcie chce replacement.
> - Read handler CloudControl zwraca tylko name/ARN/tagi - stąd rozszerzone
>   `lifecycle.ignore_changes` w `main.tf` (komentarz tamże); zmiana
>   `code_artifact` w HCL NIE robi rebuildu, rebuild = CLI + re-import.
> - Sekret ma przypiętą literówkową nazwę (`simple-cicd-repo`) przez
>   `github_app_secret_name` w tfvars - zmiana nazwy sekretu to destroy+create
>   i utrata credentiali, migracja tylko świadomie, razem z rebuildem obrazu.

> **UPDATE 2026-07-10: PEŁNY AUTOMATYCZNY E2E POTWIERDZONY.**
> `run-microvm` → `/run` hook → rejestracja przez GitHub App → job wykonany →
> runner wyrejestrowany → **self-terminate zadziałał** (punkt 8 checklisty -
> ostatnia niezweryfikowana rzecz - potwierdzony: RUNNING → TERMINATED ~10 s
> po zakończeniu joba). Checklista z sekcji 2 jest w całości wykonana.
> Po drodze cztery nowe ustalenia (wszystkie naprawione w kodzie):
> - **`RunMicrovm` z konektorem `NO_INGRESS` daje 403** "Unable to determine
>   service/operation name" - bug po stronie AWS w mapowaniu autoryzacji; to
>   samo wywołanie bez `--ingress-network-connectors` działa (default
>   `HTTP_INGRESS`; endpoint i tak wymaga tokenu JWE). Komentarz + poprawiona
>   komenda w `terraform/outputs.tf`. Sprawdzać okresowo, wrócić do NO_INGRESS.
> - **Timeout hooka `/run` ma twardy limit 60 s** (API odrzuca więcej);
>   ustawiony jawnie w obrazie i w `main.tf`. Rejestracja mieści się z zapasem
>   (~5 s), ale default był najpewniej krótszy i ubijał VM w trakcie.
> - **Sekret zawierał placeholdery `REPLACE_ME`** - prawdziwe credentiale
>   nigdy nie trafiły do AWS po którymś z odtworzeń sekretu (punkt 14 niżej);
>   ręczny happy path 2026-07-06 tego nie wykrył, bo tokeny były mintowane
>   ręcznie. Naprawione przez `put-secret-value` z lokalnego pliku.
> - **AL2023 python3 = 3.9, a boto3 porzuciło 3.9 w kwietniu 2026** - pip
>   cicho instalował starego boto3 bez modelu usługi `lambda-microvms`
>   (`UnknownServiceError` dopiero przy self-terminate). Obraz przeszedł na
>   `python3.11`, a Dockerfile ma asercję modelu usługi w czasie builda.
> - **`lambda:TerminateMicrovm` autoryzuje się względem ARN-a OBRAZU**
>   (`microvm-image:<name>`), nie instancji `microvm:*` - potwierdzone żywym
>   AccessDenied, polityka execution role poprawiona w `main.tf` (zawężenie
>   per-obraz, ciaśniejsze niż poprzedni wildcard).
> Stan końcowy: `terraform plan` = "No changes", obraz i self-terminate
> działają, następny krok z sekcji "Ograniczenia" w README to dispatcher
> (webhook `workflow_job` → `run-microvm`).

Ten dokument to migawka po sesji debugowania, w której po raz pierwszy
przeszliśmy pełny happy path (ręcznie, przez shell w MicroVM). Kod w repo
(`terraform/main.tf`, `runner-image/Dockerfile`, `runner-image/hook_server.py`,
`terraform/terraform.tfvars`) ma już naniesione **wszystkie** poprawki opisane
niżej - ten plik to log tego co i dlaczego, plus co zostało do zrobienia.

---

## 1. Co się psuło i jak to naprawiliśmy

W kolejności, w jakiej na to trafialiśmy:

1. **`dnf install` konflikt na `openssl-libs`.** Base image
   `al2023-minimal` ma już preinstalowany `openssl-snapsafe-libs` (AWS-owy,
   snapshot-safe fork OpenSSL). Jawne żądanie zwykłego `openssl-libs` w
   Dockerfile konfliktowało z nim (`dnf` słusznie odmówił podmiany - to
   ochrona przed cichym zepsuciem snapshot-compatibility, nie bug).
   **Fix:** usunięty `openssl-libs` z listy pakietów (`runner-image/Dockerfile`).

2. **`eu-west-1` pokazuje MicroVMs w konsoli, ale CLI tam nie działa.**
   `list-managed-microvm-image-versions` zwracał 403 w `eu-west-1`, a w
   `us-east-1` działał poprawnie. **Fix:** `aws_region = "us-east-1"` w
   `terraform.tfvars` (tymczasowo, patrz sekcja 3 niżej - to się okazało
   częścią większego problemu, nie tylko regionalnego).

3. **`base_image_version = ""` odrzucane przez `awscc` provider.**
   Wymaga realnej wartości (string length 1-2048, regex bez białych znaków).
   **Fix:** `base_image_version` jako wymagana zmienna, wartość `"0"`
   odczytana przez `aws lambda-microvms list-managed-microvm-image-versions`.

4. **`cpu_configurations.architecture = "arm64"` odrzucane.** Provider chce
   enuma `"ARM_64"`, nie CLI-owego stringa. **Fix:** poprawione w `main.tf`.

5. **Bug w providerze `awscc` na pustych `Set(String)`.**
   `additional_os_capabilities = []` i `egress_network_connectors = []` są
   całkowicie pomijane w requeście do Cloud Control zamiast wysłane jako
   `[]`, co Cloud Control odrzuca ("required key not found") - ta sama
   klasa co [terraform-provider-awscc#847](https://github.com/hashicorp/terraform-provider-awscc/issues/847).
   **Fix (planowany, patrz sekcja 3):** tworzenie obrazu poza Terraformem +
   `terraform import` + `lifecycle.ignore_changes` na te dwa pola. **W
   praktyce okazało się, że nawet CLI-owe tworzenie jest zablokowane (patrz
   punkt 7) - obraz ostatecznie trzeba tworzyć przez konsolę.**

6. **Zła ścieżka log grupy w naszej polityce IAM.** Dokumentacja AWS (blog +
   developer guide) pisze `/aws/lambda/microvms/<image-name>`, ale
   rzeczywista ścieżka (potwierdzona przez auto-wygenerowaną politykę
   konsoli) to `/aws/lambda-microvms/<image-name>` (jeden segment z
   myślnikiem). Zła ścieżka w naszej roli build = brak uprawnień do
   utworzenia log grupy = **zero log streama**, co wyglądało jak "build się
   nie zaczął", a naprawdę był to cichy fail na uprawnieniach do logów.
   **Fix:** `local.log_group_arn_prefix` w `main.tf` poprawiony na
   `/aws/lambda-microvms/...`.

7. **CLI zwraca 403 "Unable to determine service/operation name to be
   authorized" na `CreateMicrovmImage`, `ListMicrovmImages` - w każdym
   regionie, niezależnie od roli/uprawnień.** To osobny, poważniejszy
   problem niż punkt 2 - dotyczy zasobów *klienta* (nie tylko odczytu
   AWS-owych danych referencyjnych), i dotyczy też mutacji. Konsola AWS
   działa dla tych samych operacji. Szczegóły w sekcji 3.

8. **`KeyError: 'GITHUB_OWNER'` w logach builda.** Obraz stworzony przez
   konsolę bez wypełnienia sekcji "Environment variables" - te zmienne nie
   są częścią Terraform (bo obraz i tak nie powstaje przez `apply`, patrz
   punkt 7), trzeba je wpisać ręcznie w formularzu konsoli.

9. **`ResourceNotFoundException` przy `put-secret-value` mimo poprawnego
   ARN.** AWS CLI pyta endpoint w domyślnym regionie z profilu, nie w
   regionie zaszytym w ARN-ie. **Fix:** jawne `--region us-east-1` w
   każdym wywołaniu Secrets Managera.

10. **`json.decoder.JSONDecodeError: Invalid control character`** przy
    odczycie sekretu. `private_key` w `github-app-secret.json` miał
    prawdziwe znaki nowej linii zamiast dosłownego `\n` - poprawny JSON
    wymaga escapowania. **Fix:** budowanie pliku przez
    `jq --rawfile pk plik.pem '...'`, które samo robi escaping.

11. **`botocore.exceptions.NoRegionError` w `hook_server.py`.** W
    przeciwieństwie do klasycznej Lambdy, Lambda MicroVMs **nie wstrzykuje
    automatycznie** `AWS_REGION`/`AWS_DEFAULT_REGION` do środowiska
    kontenera. **Fix:** `AWS_REGION` jako jawna zmienna środowiskowa obrazu
    (`terraform/main.tf`) + jawny `region_name=AWS_REGION` w obu klientach
    boto3 w `hook_server.py` (Secrets Manager i `lambda-microvms`).

12. **GitHub: `'Issuer' claim ('iss') must be an Integer`.** Literalne
    placeholdery `<App ID>`/`<Installation ID>` z instrukcji zostały użyte
    dosłownie zamiast prawdziwych liczb - literówka/pomyłka, nie bug w
    kodzie.

13. **`404 Not Found` na `.../actions/runners/registration-token`.**
    GitHub App była zainstalowana na `sample-cicd-repo`, nie na
    `sample-cicd-build`, którego cały czas błędnie używaliśmy w
    konfiguracji (literówka/pomyłka z nazwą repo z samego początku
    projektu). Znalezione przez `GET /installation/repositories` z
    installation tokenem. **Fix:** `github_repo = "sample-cicd-repo"` w
    `terraform.tfvars`.

14. **`InvalidRequestException: secret ... scheduled for deletion`.** Stary
    sekret pod tą samą nazwą (z wcześniejszego testu) był w okresie
    karencji po skasowaniu. **Fix:** `aws secretsmanager delete-secret
    --force-delete-without-recovery`, potem `terraform apply` na nowo.

15. **Crash `.NET`/ICU: "Couldn't find a valid ICU package".** Wrapper
    bashowy `config.sh`/`run.sh` z tarballa `actions-runner` robi twardy
    pre-check na `libicu` przez `ldconfig` i **wychodzi z kodu 1 zanim
    .NET runtime w ogóle wystartuje** - `DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1`
    samo w sobie nie pomaga, bo runtime nigdy nie dostaje szansy to
    przeczytać. **Fix:** dodany pakiet `libicu` do `dnf install` w
    Dockerfile (zmienna env zostawiona jako dodatkowe zabezpieczenie, nie
    zamiennik).

Po tych 15 poprawkach: **pełny ręczny happy path zadziałał** - `config.sh` +
`run.sh` w shellu MicroVM zarejestrowały runnera, podjęły zdispatchowany
workflow, wykonały go, i (dzięki `--ephemeral`) same się wyrejestrowały.
Niezweryfikowana pozostaje jedynie automatyczna ścieżka przez `/run` hook
(`hook_server.py`) i self-terminate MicroVM - to jest do zrobienia jutro.

---

## 2. Checklista na jutro (w tej kolejności)

- [ ] **1. Zbuduj i wyślij nowy zip** (z poprawionym Dockerfile - `libicu`):
      ```bash
      cd runner-image
      zip -j gh-runner-image.zip Dockerfile hook_server.py requirements.txt
      aws s3 cp gh-runner-image.zip --region us-east-1 \
        s3://$(cd ../terraform && terraform output -raw artifact_bucket)/gh-runner-image.zip
      ```
- [ ] **2. Sprzątnij poprzednie testowe zasoby** (stary obraz/MicroVM
      użyty do ręcznych testów) - `terminate-microvm` w konsoli, żeby nie
      naliczał kosztów.
- [ ] **3. Stwórz obraz przez konsolę** (CLI dalej zablokowane, patrz
      sekcja 3) - Lambda → MicroVMs → Create image:
      - Name: `terraform console <<< 'local.image_name'` (w katalogu `terraform/`)
      - Code artifact: `s3://<bucket>/gh-runner-image.zip`
      - Base image ARN: `arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1`
      - Base image version: `0`
      - Build role: `terraform output -raw build_role_arn`
      - CPU: ARM64, baseline 2048 MiB
      - **Environment variables (wszystkie 6, nie zapomnieć AWS_REGION):**
        `GITHUB_OWNER=macbusik`, `GITHUB_REPO=sample-cicd-repo`,
        `GH_APP_SECRET_ARN=`(`terraform output -raw github_app_secret_arn`),
        `RUNNER_LABELS=self-hosted,microvm,ephemeral,linux,arm64`,
        `HOOK_PORT=8080`, `AWS_REGION=us-east-1`
- [ ] **4. Poczekaj na `CREATED`.** Jeśli `CREATE_FAILED` - sprawdź
      CloudWatch `/aws/lambda-microvms/<image_name>` (uwaga na myślnik, nie
      `/aws/lambda/microvms/`).
- [ ] **5. Odpal świeży MicroVM przez konsolę** - execution role:
      `terraform output -raw execution_role_arn`, ingress: `NO_INGRESS`
      (runner nie potrzebuje ruchu przychodzącego), maximum duration np.
      14400s. **Nic ręcznie w shellu tym razem** - to ma zadziałać samo
      przez `/run` hook.
- [ ] **6. Sprawdź GitHub** → `sample-cicd-repo` → Settings → Actions →
      Runners - czy runner pojawił się **sam**, bez ręcznej ingerencji.
- [ ] **7. Zdispatchuj testowy workflow** (ten sam co poprzednio,
      `runs-on: [self-hosted, microvm, ephemeral, linux, arm64]`) i
      potwierdź że job się wykonał.
- [ ] **8. Zweryfikuj self-terminate** - to jedyna rzecz jeszcze
      niepotwierdzona. Po zakończeniu joba sprawdź stan MicroVM (konsola,
      albo `aws lambda-microvms get-microvm` jeśli akurat będzie działać) -
      powinien przejść `RUNNING` → `TERMINATING` → `TERMINATED` sam, bez
      Twojej ingerencji. Jeśli utknie w `RUNNING` - sprawdź logi runtime
      pod kątem wyjątku w `_self_terminate()` (execution role bez
      `lambda:TerminateMicrovm`? region źle ustawiony? coś innego?).
- [ ] **9. Posprzątaj** - terminate wszystkie testowe MicroVMy, sprawdź
      koszty w Cost Explorer za dzisiejsze eksperymenty.
- [ ] **10. (opcjonalnie) Spróbuj `terraform import`** teraz, gdy obraz
      istnieje - może odczyt (`GetResource`/`get-microvm-image`) już
      działa mimo że tworzenie nie działało wcześniej; jeśli tak, warto to
      wciągnąć do stanu.

---

## 3. Dlaczego CLI/Terraform nie działa i co z tym zrobić

**Obserwowany wzorzec:**

| Operacja | Zasób | Wynik |
|---|---|---|
| `list-managed-microvm-image-versions` | AWS-owy base image (`arn:...:aws:microvm-image:al2023-1`) | ✅ działa (w `us-east-1`) |
| `list-microvm-images` | Zasoby klienta (Twoje obrazy) | ❌ 403 "Unable to determine service/operation name to be authorized" |
| `create-microvm-image` | Zasoby klienta | ❌ ten sam błąd |
| Konsola AWS - te same operacje | Zasoby klienta | ✅ działa |

Ten sam błąd wystąpił niezależnie od regionu (`eu-west-1` i `us-east-1`) i
niezależnie od uprawnień IAM (`get-caller-identity` potwierdzone, a
standardowy `AccessDenied` z nazwą konkretnej akcji wyglądałby inaczej -
ten komunikat to sygnatura warstwy autoryzacji/API Gateway, która nie
potrafi zmapować requestu na akcję IAM, nie odmowa na podstawie polityki).

**Wniosek:** to wygląda na niedokończony rollout API/CLI/SDK dla *zasobów
klienta* w tym bardzo świeżym serwisie (GA 2026-06-22), a nie coś do
naprawienia w naszym kodzie czy koncie. Podobny wzorzec (identyczny
komunikat błędu) był już zgłaszany dla innych świeżo wypuszczonych usług
AWS ([aws-cli#7938](https://github.com/aws/aws-cli/issues/7938) dla
`securitylake`), gdzie przyczyna leżała po stronie usługi, nie klienta.

**Co można zrobić:**

1. **Zgłoś ticket do AWS Support** z konkretnymi `RequestId`-ami z błędów,
   regionem, i dokładnymi wywołaniami CLI - to jedyny realny sposób na
   naprawę, bo problem jest po stronie AWS.
2. **Na razie: wszystko przez konsolę** - `create-microvm-image`,
   `list-microvm-images`, `run-microvm`, `terminate-microvm`. Terraform
   (`awscc_lambda_microvm_image`) zostaje jako gotowy, udokumentowany kod
   "na później" (z `lifecycle.ignore_changes` już przygotowanym), ale nie
   jest dziś używalny do tworzenia/aktualizacji tego zasobu.
3. **Nie wiadomo jeszcze, czy to dotyczy też SDK (boto3) wywoływanego
   *z wnętrza* MicroVM** (nasz `_self_terminate()`) - to inny mechanizm
   uwierzytelniania (rola wykonawcza przypisana do MicroVM, nie Twoje
   dane uwierzytelniające CLI), więc może działać inaczej. To dokładnie
   punkt 8 w checkliście na jutro - jeśli self-terminate też nie działa,
   MicroVM i tak zostanie sprzątnięty przez `maximum-duration-in-seconds`,
   tylko drożej i wolniej niż powinien.
4. **Odczekaj i sprawdzaj ponownie** - tego typu luki w rollout zwykle
   domykają się w ciągu dni-tygodni od premiery usługi.

---

## 4. Obecny stan pod kątem compliance (szczery bilans)

To działający dowód słuszności koncepcji (**proof of concept**), nie coś
gotowego do wdrożenia w regulowanym środowisku. Konkretnie:

**Sieć / ekspozycja na internet**

- `build-host/` (maszyna do budowania obrazu) ma dziś
  `associate_public_ip = true` domyślnie i security group z egress
  `0.0.0.0/0` - bo sam build (pobranie tarballa runnera z GitHuba, pakietów
  z PyPI/AL2023) tego wymaga. Brak segmentacji sieciowej, brak allowlisty
  domen, brak VPC endpoints. Ingress jest już dobrze zawężony (domyślnie
  tylko SSM, SSH opt-in) - to nie jest "szeroko otwarte na oślep", ale
  egress owszem, jest szeroki.
- Sam obraz runnera (`Dockerfile`) też ciągnie z publicznego internetu przy
  **budowie** obrazu (raz na wersję, nie per-job) - runner tarball, pakiety
  pip. Runtime egress samego uruchomionego MicroVM nie ma dziś jawnie
  skonfigurowanego VPC-egress connectora - efektywnie publiczny internet
  (potrzebny, bo runner łączy się do `api.github.com`), bez zawężenia do
  konkretnych domen/adresów.
- **Do zrobienia dla twardszego compliance:** prywatny subnet + VPC
  endpoints (S3, SSM, Secrets Manager) dla `build-host`, prywatne
  artifactory/mirror zamiast publicznego internetu przy budowie, i/lub
  `aws_lambda_network_connector` z VPC egress + firewall/proxy allowlist
  dla samego MicroVM w runtime (dziś nieużyte, ale zaprojektowane -
  `egress_network_connectors` w `main.tf` już ma na to miejsce).

**Sekrety i tożsamość**

- GitHub App private key trzymany w Secrets Manager, czytany tylko przez
  wąsko zawężoną execution role (jeden konkretny ARN sekretu) - to jest
  zrobione dobrze, zgodnie z zasadą least-privilege.
- Krótkotrwałe tokeny (installation token ~1h, registration token ~1h)
  zamiast długożyjącego PAT - też zgodnie z dobrą praktyką.
- Plik `github-app-secret.json` i klucz `.pem` leżą dziś lokalnie na
  stacji roboczej (poza repo dzięki `.gitignore`, ale bez rotacji, bez
  audytu dostępu, bez integracji z czymkolwiek typu Vault/KMS-wrapped
  storage poza samym Secrets Managerem).

**IAM**

- Build/execution role są sensownie zawężone: S3 do konkretnego
  obiektu/bucketu, `logs:*` do konkretnej log grupy, Secrets Manager do
  jednego ARN-u. `lambda:TerminateMicrovm`/`GetMicrovm` są zawężone do
  `microvm:*` w koncie (nie da się zawęzić bardziej bez znajomości ID
  MicroVM z góry - do rozważenia: tagowanie + warunki IAM oparte o tagi,
  jeśli usługa to wspiera).

**Audytowalność**

- CloudWatch logi budowy działają (po naprawie ścieżki log grupy - punkt 6
  wyżej); logi runtime MicroVM - do potwierdzenia jutro. Brak jeszcze
  eksportu/retencji/WORM (Object Lock) wspominanego w szkicu artykułu jako
  wymóg dla środowisk regulowanych. CloudTrail domyślnie łapie wywołania
  API na poziomie konta, ale nie ma dedykowanego dashboardu/alarmowania.

**Proces wdrożenia**

- Dziś **ręczny** - tworzenie obrazu i uruchamianie MicroVM przez konsolę,
  bo CLI/Terraform są zablokowane po stronie AWS (sekcja 3). To jest
  odwrotność modelu "wszystko przez PR i Terraform" opisanego jako cel w
  szkicu artykułu (sekcja 3, "Terraform only, zero ClickOps") - dziś mamy
  sporo ClickOps, tymczasowo i z jasno udokumentowanego powodu.
  Automatyczny dispatcher (webhook `workflow_job` → `run-microvm`) w ogóle
  jeszcze nie istnieje - dziś każdy MicroVM odpalamy ręcznie.

**Obraz / supply chain**

- Brak skanowania podatności (Trivy/Grype), brak SBOM, brak podpisywania
  obrazu (cosign) przed wysłaniem do S3 - `build-host/README.md` ma to w
  roadmapie, nic z tego jeszcze nie wdrożone.

**Podsumowanie jednym zdaniem:** mamy solidny, działający dowód słuszności
koncepcji z kilkoma dobrymi decyzjami architektonicznymi już na miejscu
(GitHub App zamiast PAT, krótkotrwałe tokeny, zawężone IAM, ephemeral
runner), ale zanim to nadawałoby się choćby do rozmowy o produkcji w banku,
brakuje: prywatnego VPC egress, automatycznego dispatchera zamiast
ręcznego uruchamiania, hardeningu/skanowania obrazu, i - poza naszą
kontrolą - rozwiązania przez AWS blokady CLI/Terraform dla tego serwisu.
