# 添加-x选项可输出变量的值
#!/bin/sh -x

# 文件及目录在容器外需要对应的用户及组
OUTER_DOCKER_USER_ID=997
OUTER_DOCKER_USER_GROUP_ID=993

# 容器内需要用到的变量
DB_USER='root'
DB_PWD='[PASSWORD]'
DB_HOST='127.0.0.1'
# 删除多少天前的备份
DELETE_DAYS_DURATION=30
# 需要备份的数据库名称, 多个数据库使用英文空格间隔
DB_NAMES='test'
BACKUP_DIR='/home/data/backup'
MYSQL_BIN_DIR='/var/lib/mysql'
MYSQL_BIN_INDEX_FILE="mysql-bin.index"
# 复制出来的最新的文件名
MYSQL_BIN_INDEX_NEWEST_FILE="mysql-bin.index.newest"
# 备份文件目录统一为/home/data/backup/[MONTH]/[DAY]/[FILENAME_PREFIX_DATE_NOW]
# 全量备份文件的前缀
DUMP_FILENAME_PREFIX='mysql_dump_'
# 增量备份文件的前缀
BIN_FILENAME_PREFIX='bin_log_'
# 当前时间点
MONTH_NOW=$(date "+%Y%m")
DAY_NOW=$(date "+%Y%m%d")
DATE_NOW=$(date "+%Y%m%d%H%M%S")
DATE_DIR="${BACKUP_DIR}/${MONTH_NOW}/${DAY_NOW}"
BACKUP_LOG_FILE="${BACKUP_DIR}/backup_log.log"

# 当天文件夹不存在则创建, 并进行全量备份(注意if条件语句的中括号与内部命令必须要有空格存在)
if [ ! -d ${DATE_DIR} ]; then
    # 删除指定天数前的备份
    for month_folder in $(ls -lF ${BACKUP_DIR} | grep '/$' | awk '{print $9}')
    do
        # (只遍历当前目录, 创建时间超过30天, 只查找目录(-type d))
        find ${BACKUP_DIR}/${month_folder} -maxdepth 1 -mtime +${DELETE_DAYS_DURATION} -type d | xargs rm -rf {}
        # 判断目录是否为空
        if [[ $(ls -lF ${BACKUP_DIR}/${month_folder} | grep '/$' | wc -l) -eq 0 ]]
        then
            # 为空则删除
            rm -rf ${BACKUP_DIR}/${month_folder}
        fi
    done
    # 备份前创建目录并修改权限
    echo "Create folder ${DATE_DIR}" >> ${BACKUP_LOG_FILE}
    mkdir -p ${DATE_DIR}
    # 修改权限
    cd ${BACKUP_DIR}
    chown ${OUTER_DOCKER_USER_ID}:${OUTER_DOCKER_USER_GROUP_ID} ./backup_log.log
    # 全备份完成前, 将最新的mysql-bin.index copy到备份目录下, 后续增量备份会根据此文件内容来判定应该备份哪些binlog文件
    echo "Save the latest file mysql-bin.index"
    cp ${MYSQL_BIN_DIR}/${MYSQL_BIN_INDEX_FILE} ${DATE_DIR}/${MYSQL_BIN_INDEX_FILE}
    # 具体的文件名
    DUMP_FILE="${DUMP_FILENAME_PREFIX}${DATE_NOW}"
    # 锁表、刷新日志后进行全量备份
    echo "Start full dump, date is $(date "+%Y-%m-%d %H:%M:%S")" >> ${BACKUP_LOG_FILE}
    # 进入目录
    cd ${DATE_DIR}
    mysqldump -h${DB_HOST} -u${DB_USER} -p${DB_PWD} --lock-all-tables --set-gtid-purged=off --flush-logs --source-data=2 --databases ${DB_NAMES} > ${DUMP_FILE}.sql
    # mysqldump -h${DB_HOST} -u${DB_USER} -p${DB_PWD} --set-gtid-purged=OFF --flush-logs --single-transaction --source-data=2 --databases ${DB_NAMES} > ${DUMP_FILE}.sql
    # mysqldump -h${DB_HOST} -u${DB_USER} -p${DB_PWD} --flush-logs --single-transaction --source-data=2 --databases ${DB_NAMES} > ${DATE_DIR}/${DUMP_FILE}.sql
    zip -q ${DUMP_FILE}.zip ${DUMP_FILE}.sql
    rm -f ${DUMP_FILE}.sql
    echo "Complete full dump ${DATE_DIR}/${DUMP_FILE}, date is $(date "+%Y-%m-%d %H:%M:%S")" >> ${BACKUP_LOG_FILE}
# 其他时间点进行增量备份
else
    echo "Flush bin log, date is $(date "+%Y-%m-%d %H:%M:%S")" >> ${BACKUP_LOG_FILE}
    mysqladmin -u$DB_USER -h$DB_HOST -p$DB_PWD flush-logs
    # 复制出最新的index文件
    NEWEST_BIN_FILE=${DATE_DIR}/${MYSQL_BIN_INDEX_NEWEST_FILE}
    cp ${MYSQL_BIN_DIR}/${MYSQL_BIN_INDEX_FILE} ${NEWEST_BIN_FILE}
    # 获取mysql-bin.index文件数据的行数
    # LINE_COUNT=$(wc -l ${NEWEST_BIN_FILE} | awk '{print $1}')
    # DELETED=$(sed -e ${LINE_COUNT}d ${NEWEST_BIN_FILE})
    # 删除文件中的最后一行
    sed -i '$d' ${NEWEST_BIN_FILE}
    # sed -e ${LINE_COUNT}d ${NEWEST_BIN_FILE} | tee ${NEWEST_BIN_FILE}
    DIFF_FILES=$(diff ${NEWEST_BIN_FILE} ${DATE_DIR}/${MYSQL_BIN_INDEX_FILE})
    # 备份除了文件mysql-bin.index中最后一个bin文件之外的所有文件, 若对应bin的压缩文件存在于已备份的目录, 则不备份
    BACKUP_FILE_LIST=''
    for file in ${DIFF_FILES}
    do
        # 判断结果中是否包含关键词(运算符=~两侧必须有空格)
        if [[ "${file}" =~ "mysql-bin" ]]
        then
            BASE_NAME=`basename ${file}`
            # 备份前需要先进入目录${MYSQL_BIN_DIR}
            BACKUP_FILE_LIST="${BACKUP_FILE_LIST} ./${BASE_NAME}"
        fi
    done
    FILE_LIST_LENGTH=$(expr length "${BACKUP_FILE_LIST}")
    if [[ ${FILE_LIST_LENGTH} -gt 0 ]]
    then
        echo "Start incremental backup, date is $(date "+%Y-%m-%d %H:%M:%S")" >> ${BACKUP_LOG_FILE}
        # 进入binlog目录
        cd ${MYSQL_BIN_DIR}
        zip -q ${DATE_DIR}/${BIN_FILENAME_PREFIX}${DATE_NOW}.zip ${BACKUP_FILE_LIST}
        echo "Complete incremental backup, date is $(date "+%Y-%m-%d %H:%M:%S")" >> ${BACKUP_LOG_FILE}
    fi
    # 备份之后, 将最新的mysql-bin.index.newest内容写入mysql-bin.index
    cp ${NEWEST_BIN_FILE} ${DATE_DIR}/${MYSQL_BIN_INDEX_FILE}
fi

# 修改权限
cd ${BACKUP_DIR}
chown -R ${OUTER_DOCKER_USER_ID}:${OUTER_DOCKER_USER_GROUP_ID} ./${MONTH_NOW}