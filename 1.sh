#!/bin/bash

# 设置颜色
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

# 检查是否以root权限运行
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请使用sudo运行此脚本${NC}"
    echo -e "使用方法:"
    echo -e "  sudo bash $0 域名"
    exit 1
fi

# GitHub配置
GITHUB_TOKEN="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"  # 替换为您的长期访问令牌
GITHUB_API_URL="https://api.github.com/repos/KeikoHanasaka/1/contents/1.js"
GITHUB_HTML_API="https://api.github.com/repos/KeikoHanasaka/2/contents/html"
HTML_BASE_URL="https://raw.githubusercontent.com/KeikoHanasaka/2/refs/heads/main/html"

# Cloudflare配置
CF_API_TOKEN="wGqTKSAbmc_MazGTBtExh78mh4sdgHx8e9CUQfxu"

# 获取Zone ID
get_zone_id() {
    local domain=$1
    local response=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=${domain}" \
         -H "Authorization: Bearer ${CF_API_TOKEN}" \
         -H "Content-Type: application/json")
    
    # 检查是否成功
    if echo "$response" | grep -q '"success":true'; then
        # 提取Zone ID
        local zone_id=$(echo "$response" | grep -o '"id":"[^"]*' | cut -d'"' -f4 | head -n1)
        if [ -n "$zone_id" ]; then
            echo "$zone_id"
            return 0
        fi
    fi
    
    echo -e "${RED}错误: 无法获取Zone ID，请检查域名和API Token是否正确${NC}"
    exit 1
}

# 生成随机子域名前缀（3-7个字母）
generate_subdomain() {
    length=$(( RANDOM % 5 + 3 ))  # 3到7之间的随机数
    cat /dev/urandom | tr -dc 'a-z' | fold -w $length | head -n 1
}

# 生成DKIM密钥对
generate_dkim() {
    local domain=$1
    local selector="dkim"  # DKIM选择器
    
    # 生成私钥和公钥
    openssl genrsa -out "dkim/${domain}.key" 2048 2>/dev/null
    chmod 666 "dkim/${domain}.key"  # 修改为666权限
    local public_key=$(openssl rsa -in "dkim/${domain}.key" -pubout -outform der 2>/dev/null | openssl base64 -A)
    
    # 返回DKIM记录值和选择器
    echo "${selector}:v=DKIM1; k=rsa; p=${public_key}"
}

# 创建DNS记录
create_dns_record() {
    local record_name=$1
    local record_type=$2
    local record_content=$3
    
    # 构建JSON数据，确保TXT记录内容正确引用
    local data="{
        \"type\": \"${record_type}\",
        \"name\": \"${record_name}\",
        \"content\": \"\\\"${record_content}\\\"\",
        \"ttl\": 1,
        \"proxied\": false
    }"

    local response=$(curl -s -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
         -H "Authorization: Bearer ${CF_API_TOKEN}" \
         -H "Content-Type: application/json" \
         --data "$data")
    
    # 检查是否成功
    if echo "$response" | grep -q '"success":true'; then
        echo -e "${GREEN}创建记录成功: ${record_name}${NC}"
        return 0
    else
        echo -e "${RED}创建记录失败: ${record_name}${NC}"
        echo -e "${RED}错误信息: ${response}${NC}"
        echo -e "${BLUE}请求数据: ${data}${NC}"
        return 1
    fi
}

# 下载HTML文件函数
download_html_files() {
    # 获取html文件夹中的文件列表
    files=$(curl -s -H "Accept: application/vnd.github.v3+json" "${GITHUB_HTML_API}" | grep -o '"name": "[^"]*"' | cut -d'"' -f4)
    
    # 遍历并下载每个文件
    for file in $files; do
        curl -s -L -o "html/$file" "${HTML_BASE_URL}/$file"
    done
}

# 检查是否需要sudo
need_sudo() {
    if [ "$EUID" -ne 0 ]; then
        if command -v sudo &> /dev/null; then
            echo "sudo"
        else
            echo -e "${RED}错误: 需要root权限来安装Node.js，请使用sudo运行此脚本${NC}"
            exit 1
        fi
    fi
}

# 设置DKIM和DNS记录
setup_dkim() {
    local main_domain=$1
    
    # 检查API Token是否设置
    if [ -z "$CF_API_TOKEN" ]; then
        echo -e "${RED}错误: 请提供Cloudflare API Token${NC}"
        exit 1
    fi
    
    # 获取Zone ID
    CF_ZONE_ID=$(get_zone_id $main_domain)
    
    # 检查必要工具
    if ! command -v openssl &> /dev/null; then
        echo -e "${RED}错误: 需要安装openssl${NC}"
        exit 1
    fi
    
    # 生成随机子域名
    subdomain=$(generate_subdomain)
    full_domain="${subdomain}.${main_domain}"
    
    # 生成DKIM密钥和获取记录
    dkim_info=$(generate_dkim $full_domain)
    dkim_selector=${dkim_info%%:*}
    dkim_record=${dkim_info#*:}
    
    # 创建DNS记录
    echo -e "${BLUE}创建DKIM记录...${NC}"
    create_dns_record "${dkim_selector}._domainkey.${subdomain}" "TXT" "${dkim_record}" || return 1
    
    echo -e "${BLUE}创建SPF记录...${NC}"
    create_dns_record "$subdomain" "TXT" "v=spf1 +all" || return 1
    
    echo -e "${BLUE}创建DMARC记录...${NC}"
    create_dns_record "_dmarc.${subdomain}" "TXT" "v=DMARC1; p=none; rua=mailto:dmarc-report@${full_domain}" || return 1
    
    echo -e "${GREEN}所有DNS记录创建成功${NC}"
    
    # 保存域名
    echo "$full_domain" > 域名.txt
}

# 主安装函数
main() {
    # 检查参数
    if [ -z "$1" ]; then
        echo -e "${RED}错误: 请提供主域名${NC}"
        echo "用法: $0 example.com"
        exit 1
    fi

    local main_domain=$1

    # 创建项目目录
    mkdir -p emailsender && cd emailsender || exit 1
    mkdir -p html dkim
    chmod 777 html
    chmod 777 dkim

    # 设置DKIM和DNS记录
    setup_dkim $main_domain
    chmod 666 域名.txt

    # 安装系统组件
    if ! command -v node &> /dev/null; then
        $(need_sudo) curl -fsSL https://deb.nodesource.com/setup_current.x | $(need_sudo) bash - &> /dev/null
        $(need_sudo) apt-get install -y nodejs &> /dev/null
    fi

    if ! command -v pm2 &> /dev/null; then
        $(need_sudo) npm install -g pm2 &> /dev/null
    fi

    # 创建和下载文件
    touch 收件人.txt proxy.txt proxyapi.txt 文字变量.txt 伪装域名.txt
    chmod 666 收件人.txt proxy.txt proxyapi.txt 文字变量.txt 伪装域名.txt

    curl -s -L -o "主题.txt" "https://raw.githubusercontent.com/KeikoHanasaka/2/refs/heads/main/%E4%B8%BB%E9%A2%98.js"
    chmod 666 主题.txt
    
    curl -s -L -o "发件人.txt" "https://raw.githubusercontent.com/KeikoHanasaka/2/refs/heads/main/%E5%8F%91%E4%BB%B6%E4%BA%BA.js"
    chmod 666 发件人.txt
    
    curl -s -L -o "链接.txt" "https://raw.githubusercontent.com/KeikoHanasaka/2/refs/heads/main/%E9%93%BE%E6%8E%A5.js"
    chmod 666 链接.txt

    # 下载主程序和HTML文件
    curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
         -H "Accept: application/vnd.github.v3.raw" \
         -L -o 1.js \
         "${GITHUB_API_URL}" && \
    chmod 666 1.js && \
    download_html_files && \
    chmod 666 html/* && \
    echo -e "${GREEN}文件下载成功${NC}" || echo -e "${RED}文件下载失败${NC}"

    # 安装依赖
    npm init -y &> /dev/null
    chmod 666 package.json
    npm install nodemailer moment socks &> /dev/null
    chmod 666 package-lock.json

    # 创建启动脚本
    cat > start.sh << 'EOF'
#!/bin/bash
pm2 start 1.js --no-autorestart
EOF

    cat > stop.sh << 'EOF'
#!/bin/bash
pm2 stop 1.js
pm2 delete 1.js
EOF

    chmod +x start.sh stop.sh

    echo -e "\n${GREEN}=== 安装完成 ===${NC}"
    echo -e "${BLUE}域名: $(cat 域名.txt)${NC}"
    echo -e "${BLUE}使用说明:${NC}"
    echo -e "${BLUE}启动服务: sudo bash -c 'cd emailsender && ./start.sh'${NC}"
    echo -e "${BLUE}停止服务: sudo bash -c 'cd emailsender && ./stop.sh'${NC}"
}

# 运行主函数
main "$@" 
