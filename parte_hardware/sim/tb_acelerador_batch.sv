`timescale 1ns / 1ps
//
// Testbench de lote (batch) para o acelerador DIAAS.
// Diferenças em relação a sim/tb_acelerador.sv (que continua intacto e é usado
// na verificação interativa via Questa):
//   - Não usa $stop (trava a execução em modo batch/headless); usa $finish.
//   - Le o "vetor de imagem" (1024 palavras de 32 bits) de um arquivo .hex
//     passado via +IMAGEM=... em vez de um valor fixo no código.
//   - Ao final do processamento, grava o valor do acumulador (64 bits, com
//     sinal) em decimal no arquivo indicado via +SAIDA=...
//   - Roda com um TAXA_BAUD mais alto (parametro da instancia) apenas para
//     acelerar a simulacao; o valor padrao (115200) usado na sintese/placa
//     real nao e alterado, pois nao mexemos no default do modulo.
//
module tb_acelerador_batch();

    logic clk;
    logic rst_n;
    logic rx;
    logic tx;

    // Baud "de simulacao": mais alto so para o testbench rodar rapido.
    // CLOCKS_POR_BIT = 50_000_000/5_000_000 = 10 ciclos/bit.
    localparam int TAXA_BAUD_SIM = 5_000_000;
    localparam int TEMPO_BIT     = (50_000_000 / TAXA_BAUD_SIM) * 20;

    localparam int N_PALAVRAS = 1024;
    logic [31:0] imagem [0:N_PALAVRAS-1];

    string caminho_imagem;
    string caminho_saida;
    integer fd;
    integer i;
    logic trace_ativo = 1'b0;
    logic trace_habilitado; // ligado via +TRACE (opcional, so para depuracao)

    // Monitor continuo, alinhado a borda de clock, independente de qualquer
    // calculo manual de "quantos ciclos se passaram" - evita erro de
    // alinhamento entre esperas baseadas em tempo (#TEMPO_BIT) e bordas de clk.
    always @(posedge clk) begin
        if (trace_ativo) begin
            $display("[MON t=%0t] end_esc=%0d end_leit=%0d hab_esc=%b hab_mac=%b limpa=%b dado_saida=%h peso_saida=%h mult=%h acc=%h estado=%0d",
                      $time, dut.endereco_escrita, dut.endereco_leitura, dut.fio_hab_escrita,
                      dut.fio_hab_mac, dut.fsm_inst.limpa_mac, dut.fio_dado_bram, dut.fio_peso_bram,
                      dut.mac_inst.mult_reg, dut.fio_acumulador, dut.fsm_inst.estado_atual);
        end
    end

    acelerador_top #(
        .TAXA_BAUD(TAXA_BAUD_SIM)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .rx(rx),
        .tx(tx)
    );

    always #10 clk = ~clk;

    task envia_byte_serial(input logic [7:0] dado);
        begin
            rx = 1'b0;
            #(TEMPO_BIT);
            for (int b = 0; b < 8; b++) begin
                rx = dado[b];
                #(TEMPO_BIT);
            end
            rx = 1'b1;
            #(TEMPO_BIT);
        end
    endtask

    // Envia uma palavra de 32 bits pela serial, byte mais significativo
    // primeiro. E essa ordem (confirmada em simulacao) que faz o valor
    // reconstruido pelo empacotador_bytes.sv bater exatamente com "palavra".
    task envia_palavra_serial(input logic [31:0] palavra);
        begin
            envia_byte_serial(palavra[31:24]);
            envia_byte_serial(palavra[23:16]);
            envia_byte_serial(palavra[15:8]);
            envia_byte_serial(palavra[7:0]);
        end
    endtask

    initial begin
        if (!$value$plusargs("IMAGEM=%s", caminho_imagem)) begin
            $display("ERRO: use +IMAGEM=caminho/para/imagem.hex");
            $finish;
        end
        if (!$value$plusargs("SAIDA=%s", caminho_saida)) begin
            $display("ERRO: use +SAIDA=caminho/para/saida.txt");
            $finish;
        end

        $readmemh(caminho_imagem, imagem);
        trace_habilitado = $test$plusargs("TRACE");

        clk   = 0;
        rst_n = 0;
        rx    = 1;

        #100;
        rst_n = 1;
        #100;

        for (i = 0; i < N_PALAVRAS; i = i + 1) begin
            envia_palavra_serial(imagem[i]);
            if (trace_habilitado && i == N_PALAVRAS - 2) trace_ativo = 1'b1; // liga o monitor um pouco antes do fim
        end

        // Espera o acelerador terminar o calculo de verdade. O FSM leva
        // ~1024 ciclos de clock so na fase CALCULA (um por par peso/dado),
        // entao NAO da pra simplesmente esperar um numero fixo pequeno de
        // ciclos apos o ultimo byte serial - isso lia o acumulador no meio
        // do calculo (bug encontrado nesta sessao: a versao anterior deste
        // testbench usava so 60 ciclos de folga, o que e insuficiente).
        // Espera a borda de subida de fio_fim_calculo e da uma pequena folga
        // extra (o pipeline do MAC tem 1 ciclo de atraso, entao o ultimo
        // termo so e somado ao acumulador 1-2 ciclos depois do sinal subir).
        // Um timeout de seguranca evita travar o Makefile se algo falhar.
        fork
            begin : espera_normal
                @(posedge dut.fio_fim_calculo);
                repeat (10) @(posedge clk);
            end
            begin : espera_timeout
                repeat (N_PALAVRAS + 200) @(posedge clk);
                $display("ERRO: timeout esperando fio_fim_calculo (FSM pode ter travado)");
                $finish;
            end
        join_any
        disable fork;

        trace_ativo = 1'b0;

        fd = $fopen(caminho_saida, "w");
        if (fd == 0) begin
            $display("ERRO: nao foi possivel abrir %s para escrita", caminho_saida);
            $finish;
        end
        $fdisplay(fd, "%0d", $signed(dut.fio_acumulador));
        $fclose(fd);

        $display("OK: resultado gravado em %s", caminho_saida);
        $finish;
    end

endmodule
