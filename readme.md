# Existing scripts
### Health check script
- Run `./health-check.sh`

### Exporting simulated data
- Run python3 export_window.py \
  --start 2026-11-12T17:05:00Z \
  --end   2026-11-12T17:12:00Z \
  --fault <your-fault-id> \
  --severity low \
  --onset     2026-11-12T17:07:00Z \
  --recovered 2026-11-12T17:09:00Z \
  --out <your-file-name>.csv
- Make sure you change the timestamps

### Running the experiment
- Upload your experiment yaml
- Run the following `kubectl apply -f <your-yaml-file-name>.yaml`

### Running the cloud instance
- Locate you terraform files
- In powershell, Run `terraform destroy`
- In powershell, Run `terraform apply`
- SSH in and wait for setup to finish: `ssh -i ~/.ssh/cpouta ubuntu@<new-floating-IP>`
- Run `cloud-init status --wait`
- Wait ~10 minutes

### To verify that the pods are running:
- Run `kubectl -n open5gs get pods`

### Uploading file:
- Run `scp -i ~/.ssh/<key-name> <file-name> ubuntu@<new-floating-IP>:~/`
