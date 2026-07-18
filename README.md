# GitHub Actions self-hosted runner na AWS Lambda MicroVMs

Ephemeral, repo-level self-hosted runner: jeden job = jeden MicroVM uruchomiony
ze snapshotu, rejestracja przez GitHub App (bez długożyjącego PAT), self-terminate
po zakończeniu joba.

## Struktura repo

- `terraform/` - S3 (artefakt obrazu), IAM (build role + execution role),
  Secrets Manager (dane GitHub App), obraz MicroVM zarządzany przez
  CloudFormation (`aws_cloudformation_stack` + `templates/microvm-image.yaml`;
  dlaczego nie provider `awscc` - patrz `MIGRATION_PLAN.md`).
- `runner-image/` - `Dockerfile` + `hook_server.py` (supervisor obsługujący
  hooki lifecycle AWS) + `requirements.txt`.
- `dispatcher/` - `handler.py` + `build.sh` - Lambda przyjmująca webhook
  `workflow_job` i wołająca `run-microvm` (infra w `terraform/dispatcher.tf`,
  instrukcje w sekcji "Dispatcher" niżej).
- `build-host/` - **osobny state Terraform**, jednorazowa maszyna EC2 do
  budowania/testowania obrazu z `runner-image/` bez instalowania Dockera
  lokalnie. Świadomie tymczasowe rozwiązanie - uzasadnienie i roadmapa
  hardeningu w `build-host/README.md`.

## Jak to działa (skrót)

1. `hook_server.py` startuje jako `CMD` obrazu - **nie** uruchamia runnera od razu.
2. Lambda buduje obraz z `Dockerfile` i robi snapshot Firecracker.
3. Każdy job = `run-microvm` ze snapshotu → hook `/run` pobiera dane GitHub App
   z Secrets Manager, mintuje token instalacyjny, potem token rejestracyjny
   runnera, uruchamia `config.sh --ephemeral` + `run.sh`.
4. Po zakończeniu joba (`run.sh` kończy proces) supervisor woła
   `terminate-microvm` na sobie samym - MicroVM nie zostaje "wiszący".

Szczegółowe uzasadnienie decyzji projektowych jest w komentarzach na górze
`runner-image/hook_server.py` i `terraform/main.tf`.

## Wymagania wstępne

- Region AWS: `us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1` lub
  `ap-northeast-1` (jedyne wspierane przez Lambda MicroVMs na start, 2026-06).
- Terraform >= 1.7, provider `hashicorp/aws` >= 5.60 (provider `awscc` nie
  jest już wymagany - obraz MicroVM przeszedł na CloudFormation, patrz
  `MIGRATION_PLAN.md`).
- AWS CLI >= 2.35.10 - pierwsza wersja z komendami `aws lambda-microvms`
  (ale patrz `STATUS.md` sekcja 3: część operacji CLI jest dziś zablokowana
  po stronie AWS niezależnie od wersji).
- GitHub App zainstalowany na repo docelowym (patrz niżej).
- Maszyna z Dockerem do zbudowania i przetestowania obrazu (patrz sekcja EC2 -
  celowo nie instalujemy Dockera lokalnie).

### Tworzenie GitHub App

1. GitHub → Settings (organizacji albo konta) → Developer settings → GitHub
   Apps → New GitHub App.
2. Repository permissions → **Administration: Read & write** (wymagane przez
   endpoint `POST /repos/{owner}/{repo}/actions/runners/registration-token`).
3. "Where can this app be installed": Only on this account.
4. Po utworzeniu zapisz **App ID**, wygeneruj i pobierz **private key** (.pem).
5. Install App → wybierz repo docelowe → zapisz **Installation ID** (widoczny
   w URL instalacji albo przez `GET /app/installations` z JWT aplikacji).

## Wdrożenie - trzy fazy

Obraz MicroVM (stack CloudFormation z `templates/microvm-image.yaml`) odwołuje
się do pliku w S3, który musi już istnieć w chwili `terraform apply` - stąd
rozbicie na fazy zamiast jednego `apply`.

### Faza 1 - infrastruktura bazowa (S3, IAM, kontener sekretu)

```bash
cd terraform
terraform init
terraform apply \
  -var="github_owner=<owner>" -var="github_repo=<repo>" \
  -target=aws_s3_bucket.runner_artifacts \
  -target=aws_s3_bucket_versioning.runner_artifacts \
  -target=aws_s3_bucket_public_access_block.runner_artifacts \
  -target=aws_iam_role.microvm_build_role \
  -target=aws_iam_role_policy.microvm_build_role \
  -target=aws_iam_role.microvm_execution_role \
  -target=aws_iam_role_policy.microvm_execution_role \
  -target=aws_secretsmanager_secret.github_app \
  -target=aws_secretsmanager_secret_version.github_app
```

Zanotuj `artifact_bucket` i `github_app_secret_arn` z outputu.

### Uzupełnij sekret GitHub App

Utwórz lokalnie (poza repo, plik jest w `.gitignore`) `github-app-secret.json`:

```json
{
  "app_id": "123456",
  "installation_id": "78901234",
  "private_key": "-----BEGIN RSA PRIVATE KEY-----\n...\n-----END RSA PRIVATE KEY-----\n"
}
```

```bash
aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw github_app_secret_arn)" \
  --secret-string file://github-app-secret.json
```

### Build obrazu na EC2 (bez Dockera na stacji roboczej)

Docker nie jest wymagany do stworzenia samego artefaktu zip (Lambda buduje
`Dockerfile` na własnej infrastrukturze) - jest potrzebny tylko żeby
zbudować/przetestować kontener *przed* wysłaniem go do AWS. Stąd jednorazowa,
wyrzucalna maszyna EC2 zamiast instalacji Dockera lokalnie.

Polecany typ: Graviton (`t4g.small`), Amazon Linux 2023, **arm64** - Lambda
MicroVMs działa dziś wyłącznie na ARM64, więc budowanie natywnie na arm64
oszczędza emulację QEMU.

1. Postaw maszynę przez `build-host/` (osobny, świadomie tymczasowy stack
   Terraform - patrz `build-host/README.md` dla uzasadnienia i roadmapy
   hardeningu):
   ```bash
   cd build-host
   cp example.tfvars terraform.tfvars   # uzupełnij artifact_bucket_name, subnet_id
   terraform init
   terraform apply
   terraform output -raw ssm_session_command | bash   # łączy się przez SSM, bez SSH
   ```
   Docker/git/zip są już zainstalowane przez `user_data` - maszyna jest
   gotowa od razu po połączeniu.
2. Skopiuj katalog `runner-image/` na maszynę (`git clone` tego repo).
3. Build:
   ```bash
   cd runner-image
   docker build --platform linux/arm64 -t gh-runner-microvm .
   ```
4. Opcjonalny lokalny smoke test (wymaga tych samych uprawnień do Secrets
   Manager co execution role - najprościej nadać je tymczasowo temu samemu
   instance profile w `build-host/`):
   ```bash
   docker run --rm -p 8080:8080 \
     -e GITHUB_OWNER=<owner> -e GITHUB_REPO=<repo> \
     -e GH_APP_SECRET_ARN="$(terraform output -raw github_app_secret_arn)" \
     gh-runner-microvm &
   curl -X POST http://localhost:8080/aws/lambda-microvms/runtime/v1/run \
     -d '{"microvmId":"local-smoke-test"}'
   ```
   Sprawdź w GitHub → repo → Settings → Actions → Runners, czy pojawił się
   nowy runner.
5. Zapakuj artefakt (dokładnie te 3 pliki, bez podkatalogu w zipie):
   ```bash
   zip -j gh-runner-image.zip Dockerfile hook_server.py requirements.txt
   ```
6. Wyślij do S3:
   ```bash
   aws s3 cp gh-runner-image.zip \
     "s3://$(terraform output -raw artifact_bucket)/gh-runner-image.zip"
   ```

### Faza 2 - obraz MicroVM

Obraz powstaje przez **zwykłe `terraform apply`** - Terraform tworzy stack
CloudFormation (`aws_cloudformation_stack.microvm_image` w `main.tf`), a
CloudFormation woła `CreateMicrovmImage` przez handler z rejestru. Historia:
wcześniej obraz trzeba było tworzyć przez CLI i `terraform import`, bo
provider `awscc` ma potwierdzony bug z pustymi `Set(String)` (klasa
[issue #847](https://github.com/hashicorp/terraform-provider-awscc/issues/847))
plus read handler zwracający `null` dla prawie wszystkich pól - pełna
historia i uzasadnienie migracji w `MIGRATION_PLAN.md`.

```bash
# base_image_version musi być realną wersją (pusty string jest odrzucany).
# UWAGA na format (potwierdzone 2026-07-18): handler CloudFormation chce
# POJEDYNCZEGO numeru wersji głównej ("0"), a odrzuca znormalizowaną formę
# "0.0", której wymagała stara ścieżka awscc/import.
aws lambda-microvms list-managed-microvm-image-versions \
  --image-identifier arn:aws:lambda:us-east-1:aws:microvm-image:al2023-1

terraform apply -var="base_image_version=0"   # + owner/repo

terraform output microvm_image_arn
aws lambda-microvms get-microvm-image \
  --image-identifier "$(terraform output -raw microvm_image_arn)"
# poczekaj na state: CREATED / AVAILABLE
```

Zasady po migracji:

- **Zmiana obrazu = nowa generacja.** Po zmianie artefaktu (`gh-runner-image.zip`),
  env vars czy hooków podbij `var.image_generation` (`g2` → `g3`): zmiana
  nazwy to *replacement* w CloudFormation (nowy obraz buduje się obok,
  stary jest kasowany w kroku cleanup). Celowo nie robimy in-place
  `UpdateMicrovmImage` - są doniesienia o gubieniu hooków przy update.
- **`AdditionalOsCapabilities: []` / `EgressNetworkConnectors: []`** są w
  szablonie jawnie (wariant A z `MIGRATION_PLAN.md`, Faza 1 spike). Jeśli
  create padnie z "required key not found", usuń te dwie linie z
  `templates/microvm-image.yaml` (wariant B - dokładnie to robi działająca
  ścieżka CLI) i zgłoś wynik spike'a w `MIGRATION_PLAN.md`.
- **Drift detection CloudFormation jest niewiarygodny** dla tego zasobu,
  dopóki AWS nie naprawi read handlera (zwraca `null` poza name/arn/tags) -
  kontrola kompensacyjna w `MIGRATION_PLAN.md` §6.

Logi builda: CloudWatch `/aws/lambda-microvms/<image_name>` - uwaga, jeden
segment z myślnikiem; ścieżka `/aws/lambda/microvms/...` z dokumentacji AWS
jest błędna (patrz komentarz przy `log_group_arn_prefix` w `terraform/main.tf`).

## Test end-to-end

```bash
terraform output run_microvm_example_command   # skopiuj i uruchom
aws lambda-microvms get-microvm --microvm-identifier <id z odpowiedzi run-microvm>
```

W workflow GitHub Actions:

```yaml
runs-on: [self-hosted, microvm, ephemeral, linux, arm64]
```

Po zakończeniu joba runner wyrejestrowuje się sam (`--ephemeral`), a
`hook_server.py` woła `terminate-microvm` - `get-microvm` powinien pokazać
przejście przez `TERMINATING` do `TERMINATED`.

## Dispatcher - automatyczny trigger (webhook → run-microvm)

Zamyka pętlę: job w kolejce GitHuba → świeży MicroVM, bez ręcznego
`run-microvm`. Architektura: webhook `workflow_job` → **Lambda Function URL**
(bez API Gateway - jedyną realną autoryzacją webhooka jest HMAC podpisu
`X-Hub-Signature-256`, weryfikowany w `dispatcher/handler.py`; APIGW nie
dodałby tu żadnej warstwy autoryzacji, a dodałby koszt) → `run-microvm`.

Dispatcher odpala MicroVM tylko gdy: podpis HMAC się zgadza, event to
`workflow_job` z akcją `queued`, repo się zgadza, a labele joba są
**podzbiorem** labeli naszego runnera (dokładnie ta sama reguła, którą GitHub
dobiera runnery do jobów - joby na `ubuntu-latest` nigdy nie matchują).

### Deploy

```bash
./dispatcher/build.sh    # buduje dispatcher/dispatcher.zip (bundluje boto3!)
cd terraform && terraform apply
```

`build.sh` bundluje boto3 do paczki zamiast polegać na boto3 z runtime'u
Lambdy - runtime'owy potrafi nie znać `lambda-microvms` (ta sama klasa
problemu co python3.9 w obrazie runnera, patrz `runner-image/Dockerfile`).
Asercja modelu usługi jest częścią builda. Po zmianie `handler.py` /
`requirements.txt`: ponownie `build.sh` + `apply`.

### Sekret i webhook (jednorazowo, out-of-band)

Ta sama wartość musi trafić do Secrets Managera i do konfiguracji webhooka:

```bash
cd terraform
SECRET=$(openssl rand -hex 32)

aws secretsmanager put-secret-value \
  --secret-id "$(terraform output -raw dispatcher_webhook_secret_arn)" \
  --secret-string "$SECRET" --region us-east-1

gh api "repos/<owner>/<repo>/hooks" \
  -f name=web -F active=true -f "events[]=workflow_job" \
  -f "config[url]=$(terraform output -raw dispatcher_webhook_url)" \
  -f "config[content_type]=json" \
  -f "config[secret]=$SECRET"
unset SECRET
```

GitHub od razu wysyła event `ping` - w repo → Settings → Webhooks → Recent
Deliveries powinno być zielone `200 {"message": "pong"}`.

### Test

Zdispatchuj workflow z `runs-on: [self-hosted, microvm, ephemeral, linux,
arm64]` - **bez ręcznego `run-microvm`**. Kolejność zdarzeń: delivery `queued`
→ log `Launched microvm-...` w CloudWatch `/aws/lambda/gh-runner-microvm-dispatcher`
→ runner online → job wykonany → self-terminate.

### Świadome uproszczenia

- **Redelivery / job anulowany w kolejce = jeden nadmiarowy MicroVM**, który
  nigdy nie dostanie joba i żyje aż utnie go `maximum-duration`
  (`var.dispatcher_max_duration_seconds`, domyślnie 4h - to jest realny
  koszt pomyłki, skalibruj pod swoje joby). Bez stanu deduplikacji.
- **Brak logiki kolejki/limitów współbieżności** - jeden `queued` = jeden
  `run-microvm`. Quota konta na łączną pamięć RUNNING/SUSPENDED MicroVM-ów
  jest naturalnym bezpiecznikiem.
- **Rotacja sekretu webhooka** wymaga wymiany wartości w obu miejscach
  (Secrets Manager + GitHub) i wygaśnięcia ciepłych środowisk Lambdy
  (cache per-environment, komentarz w `handler.py`).

## Ograniczenia i rzeczy do zweryfikowania

- **Tylko ARM64.** Workflow'y zależne od binariów x86 wymagają dostosowania.
- **Provider `awscc` usunięty (2026-07).** Miał dwa potwierdzone na żywo
  defekty dla `awscc_lambda_microvm_image`: puste `Set(String)` pomijane w
  requeście zamiast wysłane jako `[]` (klasa
  [terraform-provider-awscc#847](https://github.com/hashicorp/terraform-provider-awscc/issues/847),
  Cloud Control odrzuca to jako "required key not found") oraz read handler
  zwracający `null` dla wszystkiego poza name/arn/tags (wieczny drift bez
  `ignore_changes` na całości). Obraz jest teraz zarządzany przez
  CloudFormation - pełny plan migracji, ryzyka i rollback w
  `MIGRATION_PLAN.md`. Uwaga: CloudFormation używa tego samego handlera co
  Cloud Control, więc read-handlerowy defekt objawia się dalej jako
  niewiarygodny drift detection (kompensacja: §6 planu).
- **`base_image_version` musi być realną wersją, nie pustym stringiem** -
  odczytaj przez `aws lambda-microvms list-managed-microvm-image-versions`
  (patrz `terraform/variables.tf`).
- **`cpu_configurations.architecture`** to enum `"ARM_64"`, nie
  CLI-owe `"arm64"`.
- **Egress tylko publiczny internet.** Jeśli joby potrzebują dostępu do
  zasobów w prywatnym VPC, trzeba dodać network connector VPC-egress
  (`AWS::Lambda::NetworkConnector` w szablonie CloudFormation albo
  `aws_lambda_network_connector`, gdy provider `aws` go dostanie) i przekazać
  go przy `run-microvm` - oraz dopisać jego ARN do statementu
  `PassManagedNetworkConnectors` w `dispatcher.tf`.
- **Region.** Obecnie tylko `us-east-1`, `us-east-2`, `us-west-2`,
  `eu-west-1`, `ap-northeast-1` - ale patrz punkt niżej, nie wszystkie z nich
  są równo gotowe pod kątem API.
- **Nierówny rollout API per region (stan 2026-07).** `eu-west-1` pokazuje
  MicroVMs w konsoli AWS, ale jego control-plane API (to, czego używają
  CLI/SDK/Terraform) najwyraźniej jeszcze nie jest w pełni wystawione -
  `list-managed-microvm-image-versions` zwraca tam 403
  (`Unable to determine service/operation name to be authorized`, sygnatura
  usługi jeszcze niedopiętej pod spodem, nie brak uprawnień IAM), podczas gdy
  `us-east-1` odpowiada poprawnie. Stąd `terraform.tfvars` tymczasowo
  wymusza `aws_region = "us-east-1"` zamiast domyślnego `eu-west-1` z
  `variables.tf`. Wróć do `eu-west-1` (albo usuń tę linię), gdy AWS dokończy
  rollout - warto to potraktować jako regularny recheck, nie jednorazowy fix.

## Sprzątanie

```bash
terraform destroy
```

Najpierw `terminate-microvm` dla wszystkich uruchomionych instancji z tego
obrazu - serwis może odmówić usunięcia obrazu (a więc i stacka
CloudFormation), dopóki istnieją aktywne MicroVMy.
