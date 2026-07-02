# GitHub Actions self-hosted runner na AWS Lambda MicroVMs

Ephemeral, repo-level self-hosted runner: jeden job = jeden MicroVM uruchomiony
ze snapshotu, rejestracja przez GitHub App (bez długożyjącego PAT), self-terminate
po zakończeniu joba.

## Struktura repo

- `terraform/` - S3 (artefakt obrazu), IAM (build role + execution role),
  Secrets Manager (dane GitHub App), zasób `awscc_lambda_microvm_image`.
- `runner-image/` - `Dockerfile` + `hook_server.py` (supervisor obsługujący
  hooki lifecycle AWS) + `requirements.txt`.

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
- Terraform >= 1.7, provider `hashicorp/aws` >= 5.60, `hashicorp/awscc` >= 1.89.0.
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

Obraz MicroVM (`awscc_lambda_microvm_image`) odwołuje się do pliku w S3, który
musi już istnieć w chwili `terraform apply` - stąd rozbicie na fazy zamiast
jednego `apply`.

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

1. Uruchom EC2 z instance profile mającym `s3:PutObject`/`s3:GetObject` na
   buckecie z outputu `artifact_bucket`.
2. Na maszynie:
   ```bash
   sudo dnf install -y docker git zip
   sudo systemctl enable --now docker
   sudo usermod -aG docker ec2-user   # relogin po tym
   ```
3. Skopiuj katalog `runner-image/` na maszynę (`git clone` tego repo albo `scp`).
4. Build:
   ```bash
   cd runner-image
   docker build --platform linux/arm64 -t gh-runner-microvm .
   ```
5. Opcjonalny lokalny smoke test (wymaga tych samych uprawnień do Secrets
   Manager co execution role - najprościej nadać je tymczasowo temu samemu
   instance profile):
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
6. Zapakuj artefakt (dokładnie te 3 pliki, bez podkatalogu w zipie):
   ```bash
   zip -j gh-runner-image.zip Dockerfile hook_server.py requirements.txt
   ```
7. Wyślij do S3:
   ```bash
   aws s3 cp gh-runner-image.zip \
     "s3://$(terraform output -raw artifact_bucket)/gh-runner-image.zip"
   ```

### Faza 2 - obraz MicroVM

```bash
cd terraform
terraform apply -var="github_owner=<owner>" -var="github_repo=<repo>"
```

Terraform tworzy teraz `awscc_lambda_microvm_image`. Sprawdź stan builda:

```bash
aws lambda-microvms get-microvm-image \
  --image-identifier "$(terraform output -raw microvm_image_arn)"
```

Logi builda: CloudWatch `/aws/lambda/microvms/<image_name>`.

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

## Ograniczenia i rzeczy do zweryfikowania

- **Tylko ARM64.** Workflow'y zależne od binariów x86 wymagają dostosowania.
- **Brak automatycznego triggera.** MicroVM odpala się dziś ręcznie/CLI;
  webhook `workflow_job` → dispatcher (Lambda + API Gateway) → `run-microvm`
  to kolejny krok (poza zakresem tego commitu).
- **Schemat `awscc_lambda_microvm_image` nie w pełni zweryfikowany.** Pola
  `hooks`, `logging`, `base_image_version` są oznaczone jako "Required" w
  wygenerowanej dokumentacji providera, mimo że `create-microvm-image` w CLI
  traktuje je jako opcjonalne. Wartości w `terraform/main.tf` to best-effort -
  jeśli `terraform apply` je odrzuci, komunikat błędu jest najlepszym
  źródłem prawdy (funkcja wystartowała 2026-06-22, provider `awscc` dostał
  wsparcie dla niej kilka dni wcześniej - nie zdążyłem tego przepuścić przez
  żywe `terraform validate`).
- **Egress tylko publiczny internet.** Jeśli joby potrzebują dostępu do
  zasobów w prywatnym VPC, trzeba dodać `awscc_lambda_network_connector` /
  `aws_lambda_network_connector` (VPC egress) i przekazać go przy
  `run-microvm`.
- **Region.** Obecnie tylko `us-east-1`, `us-east-2`, `us-west-2`,
  `eu-west-1`, `ap-northeast-1`.

## Sprzątanie

```bash
terraform destroy
```

Najpierw `terminate-microvm` dla wszystkich uruchomionych instancji z tego
obrazu - `awscc_lambda_microvm_image` może odmówić usunięcia, dopóki istnieją
aktywne MicroVMy.
