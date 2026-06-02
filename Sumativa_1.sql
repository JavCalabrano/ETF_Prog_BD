
SET SERVEROUTPUT OFF;
 

TRUNCATE TABLE DETALLE_DE_CLIENTES;

-- Declaración de variables BIND para ocupar en el PL/SQL
VAR b_periodo_pro VARCHAR;
VAR b_mes_pro NUMBER;
VAR b_id_progresivo NUMBER;

-- Inicialización de variables BIND
EXEC :b_periodo_pro := TO_CHAR(SYSDATE, 'MMYYYY');
EXEC :b_mes_pro := TO_CHAR(SYSDATE, 'mm');
EXEC :b_id_progresivo := 10;

-- Bloque de PL/SQL

DECLARE
    v_primer_id cliente.id_cli%TYPE;
    v_ult_id cliente.id_cli%TYPE;
    v_total_ids NUMBER(8);
    v_run_cliente cliente.numrun_cli%TYPE;
    v_nomb_completo VARCHAR2(200);
    v_edad NUMBER(3);
    v_puntaje NUMBER(10);
    v_email VARCHAR2(200);
    v_periodo_pro VARCHAR2(6);
    v_contador NUMBER(3);

BEGIN 
    v_contador := 1;
    v_periodo_pro := TO_CHAR(SYSDATE, 'YYYY');
    -- Definimos los limites para la iteración del ciclo
    SELECT
        MIN(id_cli),
        MAX(id_cli),
        COUNT(id_cli)
    INTO v_primer_id, v_ult_id, v_total_ids
    FROM cliente;
    
    -- Prueba - impresion de limites para la iteración
    DBMS_OUTPUT.PUT_LINE(v_primer_id);
    DBMS_OUTPUT.PUT_LINE(v_ult_id);
    DBMS_OUTPUT.PUT_LINE(v_total_ids);
    
    -- Ciclo que recorre todos los registros de tabla Cliente
    FOR i IN v_contador .. v_total_ids LOOP
        
        SELECT 
        numrun_cli AS rut,
        appaterno_cli || ' ' || apmaterno_cli || ' ' || pnombre_cli AS cliente,
        TRUNC(MONTHS_BETWEEN(SYSDATE, fecha_nac_cli) / 12) AS edad,
        CASE
            -- filtro de comuna y renta 800.000
            WHEN renta > 800000 AND id_comuna NOT IN (80, 85, 84) THEN (renta / 100) * 3 
            -- filtro de edad
            WHEN id_tipo_cli IN ('D', 'B') THEN TRUNC(MONTHS_BETWEEN(SYSDATE, fecha_nac_cli) / 12) * 30
            -- filtro tramo 16 a 25
            WHEN (SYSDATE - fecha_nac_cli) >15 AND (SYSDATE - fecha_nac_cli) <26 THEN (renta / 100) * 8 
            -- filtro tramo 26 a 10000
            WHEN (SYSDATE - fecha_nac_cli) >25 THEN (renta / 100) * 11
            ELSE 0
            -- FILTROS FUNCIONALES    
            END AS puntaje,
            -- cORREO
            LOWER((appaterno_cli) || TRUNC((MONTHS_BETWEEN(SYSDATE, fecha_nac_cli) / 12)) || '*' || SUBSTR(pnombre_cli, 1, 1) || 
            SUBSTR(TO_CHAR(fecha_nac_cli), 1, 2) || TO_CHAR(SYSDATE, 'mm')) || '@logicard.cl' AS correo,
            v_periodo_pro as periodo    
        INTO v_run_cliente, v_nomb_completo, v_edad, v_puntaje, v_email, v_periodo_pro
        FROM CLIENTE
        WHERE id_cli = b_id_progresivo;
    
    DBMS_OUTPUT.PUT_LINE(i);
    DBMS_OUTPUT.PUT_LINE(v_run_cliente);
    DBMS_OUTPUT.PUT_LINE(v_nomb_completo);
    DBMS_OUTPUT.PUT_LINE(v_edad);
    DBMS_OUTPUT.PUT_LINE(v_puntaje);
    DBMS_OUTPUT.PUT_LINE(v_email);
    DBMS_OUTPUT.PUT_LINE(v_periodo_pro);
    DBMS_OUTPUT.PUT_LINE(' ');
    
    :b_id_progresivo := :b_id_progresivo + 5;
    
    END LOOP;
    
    

END;
/