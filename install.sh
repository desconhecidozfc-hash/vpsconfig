#!/bin/bash

# ============================================
# MonoBuild VPS Deploy Manager - Instalador
# ============================================
# Execute com: curl -fsSL https://seu-dominio.com/install.sh | sudo bash
# Ou: wget -qO- https://seu-dominio.com/install.sh | sudo bash
# ============================================

set -e

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Banner
echo -e "${PURPLE}"
echo "  __  __                   ____        _ _     _ "
echo " |  \/  | ___  _ __   ___ | __ ) _   _(_) | __| |"
echo " | |\/| |/ _ \| '_ \ / _ \|  _ \| | | | | |/ _\` |"
echo " | |  | | (_) | | | | (_) | |_) | |_| | | | (_| |"
echo " |_|  |_|\___/|_| |_|\___/|____/ \__,_|_|_|\__,_|"
echo -e "${NC}"
echo -e "${CYAN}VPS Deploy Manager - Instalador Automático${NC}"
echo "============================================"
echo ""

# Verificar root
if [ "$EUID" -ne 0 ]; then 
  echo -e "${RED}❌ Execute como root: sudo bash install.sh${NC}"
  exit 1
fi

# Detectar OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${RED}❌ Sistema operacional não suportado${NC}"
    exit 1
fi

if [ "$OS" != "ubuntu" ] && [ "$OS" != "debian" ]; then
    echo -e "${RED}❌ Este instalador suporta apenas Ubuntu/Debian${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Sistema detectado: $PRETTY_NAME${NC}"
echo ""

# Pedir configurações
echo -e "${YELLOW}📝 Configuração${NC}"
echo "---------------"

read -p "Porta da API (padrão: 4387): " API_PORT
API_PORT=${API_PORT:-4387}

# Gerar chave secreta aleatória
DEFAULT_SECRET=$(openssl rand -hex 32)
read -p "Chave secreta (Enter para gerar automaticamente): " DEPLOY_SECRET
DEPLOY_SECRET=${DEPLOY_SECRET:-$DEFAULT_SECRET}

read -p "Seu domínio (opcional, para SSL): " DOMAIN

echo ""
echo -e "${BLUE}[1/7] Atualizando sistema...${NC}"
apt-get update -qq
apt-get upgrade -y -qq

echo -e "${BLUE}[2/7] Instalando dependências...${NC}"
apt-get install -y -qq curl wget git ca-certificates gnupg lsb-release ufw

echo -e "${BLUE}[3/7] Instalando Docker...${NC}"
if ! command -v docker &> /dev/null; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable docker
    systemctl start docker
    echo -e "${GREEN}✓ Docker instalado${NC}"
else
    echo -e "${GREEN}✓ Docker já instalado${NC}"
fi

echo -e "${BLUE}[4/7] Instalando Node.js 20...${NC}"
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
    apt-get install -y -qq nodejs
    echo -e "${GREEN}✓ Node.js instalado${NC}"
else
    echo -e "${GREEN}✓ Node.js já instalado$(node -v)${NC}"
fi

echo -e "${BLUE}[5/7] Instalando PM2...${NC}"
npm install -g pm2 -q 2>/dev/null
echo -e "${GREEN}✓ PM2 instalado${NC}"

echo -e "${BLUE}[6/7] Configurando MonoBuild Deploy Manager...${NC}"

# Criar diretórios
mkdir -p /opt/monobuild-deploy/projects
mkdir -p /opt/monobuild-deploy/logs

# Baixar arquivos do servidor (ou criar inline)
cat > /opt/monobuild-deploy/package.json << 'PACKAGE_EOF'
{
  "name": "monobuild-deploy-manager",
  "version": "1.0.0",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "cors": "^2.8.5",
    "dockerode": "^4.0.0",
    "uuid": "^9.0.0"
  }
}
PACKAGE_EOF


# Criar servidor inline
cat > /opt/monobuild-deploy/server.js << 'SERVER_EOF'
const express = require('express');
const cors = require('cors');
const Docker = require('dockerode');
const { v4: uuidv4 } = require('uuid');
const fs = require('fs');
const path = require('path');

const app = express();
const docker = new Docker({ socketPath: '/var/run/docker.sock' });

const PORT = process.env.PORT || 4387;
const DEPLOY_SECRET = process.env.DEPLOY_SECRET || 'change-me';
const MAX_DEPLOYS_PER_USER = 10;
const PROJECT_TIMEOUT_MS = 30 * 60 * 1000;
const BASE_PORT = 10000;
const MAX_PORT = 10100;
const PROJECTS_DIR = '/opt/monobuild-deploy/projects';

const deployments = new Map();
const userDeploys = new Map();
const usedPorts = new Set();

app.use(cors());
app.use(express.json({ limit: '50mb' }));

const authenticate = (req, res, next) => {
  if (req.headers['x-deploy-secret'] !== DEPLOY_SECRET) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
};

const findAvailablePort = () => {
  for (let port = BASE_PORT; port <= MAX_PORT; port++) {
    if (!usedPorts.has(port)) { usedPorts.add(port); return port; }
  }
  return null;
};

const releasePort = (port) => usedPorts.delete(port);

const createDockerfile = () => `FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install --production
COPY . .
EXPOSE 3000
CMD ["npm", "start"]
`;

const cleanupDeployment = async (deployId) => {
  const deployment = deployments.get(deployId);
  if (!deployment) return;
  try {
    const container = docker.getContainer(deployment.containerId);
    await container.stop().catch(() => {});
    await container.remove().catch(() => {});
  } catch (err) {}
  const projectDir = path.join(PROJECTS_DIR, deployId);
  if (fs.existsSync(projectDir)) fs.rmSync(projectDir, { recursive: true, force: true });
  releasePort(deployment.port);
  const userDeploySet = userDeploys.get(deployment.userId);
  if (userDeploySet) userDeploySet.delete(deployId);
  deployments.delete(deployId);
  console.log(`🗑️ Cleaned: ${deployId}`);
};

app.post('/deploy', authenticate, async (req, res) => {
  try {
    const { userId, projectName, files, existingDeployId } = req.body;
    if (!userId || !files) return res.status(400).json({ error: 'Missing data' });

    let userDeploySet = userDeploys.get(userId) || new Set();
    userDeploys.set(userId, userDeploySet);

    if (existingDeployId && deployments.has(existingDeployId)) {
      await cleanupDeployment(existingDeployId);
    } else if (userDeploySet.size >= MAX_DEPLOYS_PER_USER) {
      return res.status(429).json({ error: `Limite de ${MAX_DEPLOYS_PER_USER} deploys` });
    }

    const deployId = existingDeployId || uuidv4().slice(0, 8);
    const port = findAvailablePort();
    if (!port) return res.status(503).json({ error: 'Sem portas' });

    console.log(`🚀 Deploy: ${deployId}`);
    const projectDir = path.join(PROJECTS_DIR, deployId);
    fs.mkdirSync(projectDir, { recursive: true });

    for (const file of files) {
      const filePath = path.join(projectDir, file.path);
      fs.mkdirSync(path.dirname(filePath), { recursive: true });
      fs.writeFileSync(filePath, file.content);
    }

    const pkgPath = path.join(projectDir, 'package.json');
    if (!fs.existsSync(pkgPath)) {
      fs.writeFileSync(pkgPath, JSON.stringify({
        name: 'project', version: '1.0.0',
        scripts: { start: 'node server.js' },
        dependencies: { express: '^4.18.2', cors: '^2.8.5' }
      }, null, 2));
    }

    fs.writeFileSync(path.join(projectDir, 'Dockerfile'), createDockerfile());

    const imageName = `monobuild-${deployId}`;
    const stream = await docker.buildImage({ context: projectDir, src: fs.readdirSync(projectDir) }, { t: imageName });
    await new Promise((resolve, reject) => {
      docker.modem.followProgress(stream, (err) => err ? reject(err) : resolve(), (e) => e.stream && process.stdout.write(e.stream));
    });

    const container = await docker.createContainer({
      Image: imageName, name: `monobuild-${deployId}`,
      ExposedPorts: { '3000/tcp': {} },
      HostConfig: {
        PortBindings: { '3000/tcp': [{ HostPort: port.toString() }] },
        Memory: 256 * 1024 * 1024, CpuShares: 256
      },
      Env: ['PORT=3000']
    });
    await container.start();

    deployments.set(deployId, { userId, port, containerId: container.id, lastAccess: Date.now(), projectName, createdAt: new Date().toISOString() });
    userDeploySet.add(deployId);

    await new Promise(r => setTimeout(r, 2000));
    const host = req.headers.host?.split(':')[0] || 'localhost';
    res.json({ success: true, deployId, url: `http://${host}:${port}`, port });
  } catch (error) {
    console.error(error);
    res.status(500).json({ error: error.message });
  }
});

app.get('/deploys/:userId', authenticate, (req, res) => {
  const userDeploySet = userDeploys.get(req.params.userId);
  if (!userDeploySet) return res.json({ deploys: [], limit: MAX_DEPLOYS_PER_USER, used: 0 });
  const deploys = [...userDeploySet].map(id => {
    const d = deployments.get(id);
    return d ? { deployId: id, projectName: d.projectName, url: `http://${req.headers.host?.split(':')[0]}:${d.port}`, createdAt: d.createdAt } : null;
  }).filter(Boolean);
  res.json({ deploys, limit: MAX_DEPLOYS_PER_USER, used: deploys.length });
});

app.delete('/deploy/:deployId', authenticate, async (req, res) => {
  if (!deployments.has(req.params.deployId)) return res.status(404).json({ error: 'Not found' });
  await cleanupDeployment(req.params.deployId);
  res.json({ success: true });
});

app.get('/deploy/:deployId/status', authenticate, async (req, res) => {
  const d = deployments.get(req.params.deployId);
  if (!d) return res.status(404).json({ error: 'Not found' });
  try {
    const info = await docker.getContainer(d.containerId).inspect();
    d.lastAccess = Date.now();
    res.json({ deployId: req.params.deployId, status: info.State.Running ? 'running' : 'stopped', url: `http://${req.headers.host?.split(':')[0]}:${d.port}` });
  } catch (e) { res.json({ status: 'error', error: e.message }); }
});

app.get('/deploy/:deployId/logs', authenticate, async (req, res) => {
  const d = deployments.get(req.params.deployId);
  if (!d) return res.status(404).json({ error: 'Not found' });
  try {
    const logs = await docker.getContainer(d.containerId).logs({ stdout: true, stderr: true, tail: 100 });
    res.json({ logs: logs.toString() });
  } catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/health', (req, res) => res.json({ status: 'ok', totalDeploys: deployments.size, usedPorts: usedPorts.size }));

setInterval(async () => {
  const now = Date.now();
  for (const [id, d] of deployments) {
    if (now - d.lastAccess > PROJECT_TIMEOUT_MS) {
      console.log(`⏰ Timeout: ${id}`);
      await cleanupDeployment(id);
    }
  }
}, 60000);

app.listen(PORT, '0.0.0.0', () => console.log(`🚀 MonoBuild Deploy Manager on port ${PORT}`));
SERVER_EOF


# Criar arquivo .env
cat > /opt/monobuild-deploy/.env << ENV_EOF
DEPLOY_SECRET=$DEPLOY_SECRET
PORT=$API_PORT
ENV_EOF

# Instalar dependências
cd /opt/monobuild-deploy
npm install --quiet 2>/dev/null

echo -e "${GREEN}✓ Servidor configurado${NC}"

echo -e "${BLUE}[7/7] Configurando firewall e iniciando serviço...${NC}"

# Configurar UFW
ufw allow $API_PORT/tcp > /dev/null 2>&1
ufw allow 10000:10100/tcp > /dev/null 2>&1

# Parar instância anterior se existir
pm2 delete monobuild-deploy 2>/dev/null || true

# Iniciar com PM2
cd /opt/monobuild-deploy
pm2 start server.js --name monobuild-deploy --env production > /dev/null 2>&1
pm2 save > /dev/null 2>&1
pm2 startup systemd -u root --hp /root > /dev/null 2>&1 || true

echo -e "${GREEN}✓ Serviço iniciado${NC}"

# Pegar IP público
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || curl -s icanhazip.com 2>/dev/null || echo "SEU_IP")

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}✅ INSTALAÇÃO CONCLUÍDA!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${CYAN}📡 Informações do servidor:${NC}"
echo -e "   URL da API: ${YELLOW}http://$PUBLIC_IP:$API_PORT${NC}"
echo -e "   Chave secreta: ${YELLOW}$DEPLOY_SECRET${NC}"
echo ""
echo -e "${CYAN}🔧 Configure no MonoBuild:${NC}"
echo -e "   1. Vá em Servidor → VPS (Produção) → ⚙️"
echo -e "   2. URL: ${YELLOW}http://$PUBLIC_IP:$API_PORT${NC}"
echo -e "   3. Chave: ${YELLOW}$DEPLOY_SECRET${NC}"
echo ""
echo -e "${CYAN}📋 Comandos úteis:${NC}"
echo -e "   Ver logs:     ${YELLOW}pm2 logs monobuild-deploy${NC}"
echo -e "   Reiniciar:    ${YELLOW}pm2 restart monobuild-deploy${NC}"
echo -e "   Status:       ${YELLOW}pm2 status${NC}"
echo -e "   Containers:   ${YELLOW}docker ps${NC}"
echo ""

if [ -n "$DOMAIN" ]; then
    echo -e "${PURPLE}🌐 Para configurar SSL com seu domínio ($DOMAIN):${NC}"
    echo -e "   1. Aponte o DNS A record para: $PUBLIC_IP"
    echo -e "   2. Execute: ${YELLOW}apt install certbot python3-certbot-nginx${NC}"
    echo -e "   3. Execute: ${YELLOW}certbot --nginx -d $DOMAIN${NC}"
    echo ""
fi

echo -e "${GREEN}🎉 Pronto para receber deploys!${NC}"
