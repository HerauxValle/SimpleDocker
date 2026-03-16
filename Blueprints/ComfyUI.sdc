[meta]
name         = comfyui
port         = 8188
dialogue     = Stable Diffusion UI
description  = ComfyUI — node-based Stable Diffusion UI with Manager plugin.
storage_type = comfyui
gpu          = cuda_auto
entrypoint   = venv/bin/python main.py --listen 0.0.0.0 --port 8188

[env]
PORT = 8188
HOST = 0.0.0.0

[storage]
models, output, input, custom_nodes, user

[deps]
python3, curl, git

[dirs]
models, output, input, custom_nodes, user, logs

[pip]
torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu124

[git]
comfyanonymous/ComfyUI source → .
ltdrdata/ComfyUI-Manager source → custom_nodes/ComfyUI-Manager

[install]
venv/bin/pip install -r requirements.txt
venv/bin/pip install -r custom_nodes/ComfyUI-Manager/requirements.txt

