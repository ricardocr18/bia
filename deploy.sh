#!/bin/bash

# Script de Deploy para ECS - Projeto BIA
# Autor: Amazon Q
# Versão: 1.0

set -e

# Configurações padrão
ECR_REPOSITORY="bia-app"
ECS_CLUSTER="bia-cluster-alb"
ECS_SERVICE="bia-service"
TASK_DEFINITION="bia-tf"
AWS_REGION="us-east-1"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Função para exibir help
show_help() {
    echo -e "${BLUE}=== Script de Deploy ECS - Projeto BIA ===${NC}"
    echo ""
    echo -e "${GREEN}DESCRIÇÃO:${NC}"
    echo "  Script para build, push e deploy de aplicações no ECS com versionamento por commit hash"
    echo ""
    echo -e "${GREEN}USO:${NC}"
    echo "  $0 [COMANDO] [OPÇÕES]"
    echo ""
    echo -e "${GREEN}COMANDOS:${NC}"
    echo "  deploy              Executa build, push e deploy completo"
    echo "  build               Apenas faz build da imagem Docker"
    echo "  push                Apenas faz push da imagem para ECR"
    echo "  update-service      Apenas atualiza o serviço ECS"
    echo "  rollback [TAG]      Faz rollback para uma versão específica"
    echo "  list-versions       Lista as últimas 10 versões disponíveis no ECR"
    echo "  help                Exibe esta ajuda"
    echo ""
    echo -e "${GREEN}OPÇÕES:${NC}"
    echo "  -r, --region REGION    Região AWS (padrão: us-east-1)"
    echo "  -c, --cluster CLUSTER  Nome do cluster ECS (padrão: bia-cluster-alb)"
    echo "  -s, --service SERVICE  Nome do serviço ECS (padrão: bia-service)"
    echo "  -e, --ecr REPOSITORY   Nome do repositório ECR (padrão: bia-app)"
    echo "  -t, --tag TAG          Tag específica para usar (padrão: commit hash)"
    echo "  --dry-run              Simula as ações sem executar"
    echo ""
    echo -e "${GREEN}EXEMPLOS:${NC}"
    echo "  $0 deploy                           # Deploy completo com commit atual"
    echo "  $0 deploy -r us-west-2              # Deploy em região específica"
    echo "  $0 rollback abc123f                 # Rollback para commit abc123f"
    echo "  $0 list-versions                    # Lista versões disponíveis"
    echo "  $0 build --dry-run                  # Simula build sem executar"
    echo ""
    echo -e "${GREEN}FLUXO DE DEPLOY:${NC}"
    echo "  1. Obtém hash do commit atual (últimos 7 caracteres)"
    echo "  2. Faz build da imagem Docker com tag do commit"
    echo "  3. Faz push da imagem para ECR"
    echo "  4. Cria nova task definition com a imagem"
    echo "  5. Atualiza o serviço ECS"
    echo "  6. Aguarda deploy completar"
    echo ""
    echo -e "${YELLOW}NOTA:${NC} Certifique-se de ter as credenciais AWS configuradas e permissões adequadas."
}

# Função para log colorido
log() {
    local level=$1
    shift
    case $level in
        "INFO")  echo -e "${GREEN}[INFO]${NC} $*" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $*" ;;
        "ERROR") echo -e "${RED}[ERROR]${NC} $*" ;;
        "DEBUG") echo -e "${BLUE}[DEBUG]${NC} $*" ;;
    esac
}

# Função para verificar dependências
check_dependencies() {
    log "INFO" "Verificando dependências..."
    
    local deps=("docker" "aws" "git" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            log "ERROR" "$dep não está instalado"
            exit 1
        fi
    done
    
    # Verifica se está em um repositório git
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        log "ERROR" "Este diretório não é um repositório git"
        exit 1
    fi
    
    log "INFO" "Todas as dependências estão OK"
}

# Função para obter commit hash
get_commit_hash() {
    if [[ -n "$CUSTOM_TAG" ]]; then
        echo "$CUSTOM_TAG"
    else
        git rev-parse --short=7 HEAD
    fi
}

# Função para obter account ID da AWS
get_aws_account_id() {
    aws sts get-caller-identity --query Account --output text --region $AWS_REGION
}

# Função para fazer build da imagem
build_image() {
    local tag=$1
    local ecr_uri="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${tag}"
    
    log "INFO" "Fazendo build da imagem com tag: $tag"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DEBUG" "DRY RUN: docker build -t $ECR_REPOSITORY:$tag -t $ecr_uri ."
        echo "$ecr_uri"
        return 0
    fi
    
    docker build -t $ECR_REPOSITORY:$tag -t $ecr_uri .
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Build concluído com sucesso"
        echo "$ecr_uri"
    else
        log "ERROR" "Falha no build da imagem"
        exit 1
    fi
}

# Função para fazer push da imagem
push_image() {
    local ecr_uri=$1
    
    log "INFO" "Fazendo login no ECR..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DEBUG" "DRY RUN: aws ecr get-login-password | docker login"
        log "DEBUG" "DRY RUN: docker push $ecr_uri"
        return 0
    fi
    
    aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com
    
    log "INFO" "Fazendo push da imagem: $ecr_uri"
    docker push "$ecr_uri"
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Push concluído com sucesso"
    else
        log "ERROR" "Falha no push da imagem"
        exit 1
    fi
}

# Função para criar nova task definition
create_task_definition() {
    local image_uri=$1
    local tag=$2
    
    log "INFO" "Criando nova task definition com imagem: $image_uri"
    
    # Obtém a task definition atual
    local current_td=$(aws ecs describe-task-definition --task-definition $TASK_DEFINITION --region $AWS_REGION --query 'taskDefinition')
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Falha ao obter task definition atual"
        exit 1
    fi
    
    # Remove campos desnecessários e atualiza a imagem
    local new_td=$(echo $current_td | jq --arg image "$image_uri" '
        del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .placementConstraints, .compatibilities, .registeredAt, .registeredBy) |
        .containerDefinitions[0].image = $image
    ')
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DEBUG" "DRY RUN: Criaria nova task definition com imagem $image_uri"
        echo "bia-tf:999" # Fake revision para dry run
        return 0
    fi
    
    # Registra nova task definition
    local result=$(aws ecs register-task-definition --region $AWS_REGION --cli-input-json "$new_td")
    local new_revision=$(echo $result | jq -r '.taskDefinition.taskDefinitionArn' | cut -d':' -f6)
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Nova task definition criada: $TASK_DEFINITION:$new_revision"
        echo "$TASK_DEFINITION:$new_revision"
    else
        log "ERROR" "Falha ao criar nova task definition"
        exit 1
    fi
}

# Função para atualizar serviço ECS
update_service() {
    local task_definition_arn=$1
    
    log "INFO" "Atualizando serviço ECS: $ECS_SERVICE"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DEBUG" "DRY RUN: aws ecs update-service --cluster $ECS_CLUSTER --service $ECS_SERVICE --task-definition $task_definition_arn"
        return 0
    fi
    
    aws ecs update-service \
        --cluster $ECS_CLUSTER \
        --service $ECS_SERVICE \
        --task-definition $task_definition_arn \
        --region $AWS_REGION > /dev/null
    
    if [[ $? -eq 0 ]]; then
        log "INFO" "Serviço atualizado com sucesso"
        log "INFO" "Aguardando deploy completar..."
        
        aws ecs wait services-stable \
            --cluster $ECS_CLUSTER \
            --services $ECS_SERVICE \
            --region $AWS_REGION
        
        if [[ $? -eq 0 ]]; then
            log "INFO" "Deploy concluído com sucesso!"
        else
            log "WARN" "Timeout aguardando estabilização do serviço"
        fi
    else
        log "ERROR" "Falha ao atualizar serviço"
        exit 1
    fi
}

# Função para listar versões disponíveis
list_versions() {
    log "INFO" "Listando últimas 10 versões disponíveis no ECR..."
    
    aws ecr describe-images \
        --repository-name $ECR_REPOSITORY \
        --region $AWS_REGION \
        --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt]' \
        --output table
}

# Função para fazer rollback
rollback() {
    local target_tag=$1
    
    if [[ -z "$target_tag" ]]; then
        log "ERROR" "Tag de destino é obrigatória para rollback"
        echo "Use: $0 rollback <tag>"
        echo "Para ver versões disponíveis: $0 list-versions"
        exit 1
    fi
    
    log "INFO" "Iniciando rollback para versão: $target_tag"
    
    local image_uri="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${target_tag}"
    
    # Verifica se a imagem existe
    aws ecr describe-images \
        --repository-name $ECR_REPOSITORY \
        --image-ids imageTag=$target_tag \
        --region $AWS_REGION > /dev/null 2>&1
    
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Imagem com tag '$target_tag' não encontrada no ECR"
        log "INFO" "Versões disponíveis:"
        list_versions
        exit 1
    fi
    
    # Cria nova task definition e atualiza serviço
    local new_td=$(create_task_definition $image_uri $target_tag)
    update_service $new_td
    
    log "INFO" "Rollback para versão $target_tag concluído!"
}

# Função principal de deploy
deploy() {
    check_dependencies
    
    local commit_hash=$(get_commit_hash)
    log "INFO" "Iniciando deploy com commit: $commit_hash"
    
    # Build da imagem
    local image_uri
    image_uri=$(build_image $commit_hash)
    
    # Push da imagem
    push_image "$image_uri"
    
    # Cria nova task definition
    local new_td=$(create_task_definition "$image_uri" $commit_hash)
    
    # Atualiza serviço
    update_service "$new_td"
    
    log "INFO" "Deploy completo finalizado!"
    log "INFO" "Versão deployada: $commit_hash"
}

# Parse dos argumentos
COMMAND=""
DRY_RUN="false"
CUSTOM_TAG=""

while [[ $# -gt 0 ]]; do
    case $1 in
        deploy|build|push|update-service|rollback|list-versions|help)
            COMMAND=$1
            shift
            ;;
        -r|--region)
            AWS_REGION="$2"
            shift 2
            ;;
        -c|--cluster)
            ECS_CLUSTER="$2"
            shift 2
            ;;
        -s|--service)
            ECS_SERVICE="$2"
            shift 2
            ;;
        -e|--ecr)
            ECR_REPOSITORY="$2"
            shift 2
            ;;
        -t|--tag)
            CUSTOM_TAG="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        *)
            if [[ "$COMMAND" == "rollback" && -z "$2" ]]; then
                ROLLBACK_TAG="$1"
            else
                log "ERROR" "Opção desconhecida: $1"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# Obtém AWS Account ID se não for dry run
if [[ "$DRY_RUN" != "true" ]]; then
    AWS_ACCOUNT_ID=$(get_aws_account_id)
    if [[ $? -ne 0 ]]; then
        log "ERROR" "Falha ao obter AWS Account ID. Verifique suas credenciais."
        exit 1
    fi
fi

# Executa comando
case $COMMAND in
    "deploy")
        deploy
        ;;
    "build")
        check_dependencies
        build_image $(get_commit_hash)
        ;;
    "push")
        check_dependencies
        local commit_hash=$(get_commit_hash)
        local image_uri="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${commit_hash}"
        push_image $image_uri
        ;;
    "update-service")
        check_dependencies
        local commit_hash=$(get_commit_hash)
        local image_uri="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY}:${commit_hash}"
        local new_td=$(create_task_definition $image_uri $commit_hash)
        update_service $new_td
        ;;
    "rollback")
        check_dependencies
        rollback ${ROLLBACK_TAG}
        ;;
    "list-versions")
        list_versions
        ;;
    "help"|"")
        show_help
        ;;
    *)
        log "ERROR" "Comando desconhecido: $COMMAND"
        show_help
        exit 1
        ;;
esac
