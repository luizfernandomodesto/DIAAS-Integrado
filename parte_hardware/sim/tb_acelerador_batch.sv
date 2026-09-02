`timescale 1ns / 1ps

module tb_acelerador_batch();

    logic clk;
    logic rst_n;
    logic rx;
    logic tx;

    localparam int TAXA_BAUD_SIM = 16_000_000;
    localparam int TEMPO_BIT     = (50_000_000 / TAXA_BAUD_SIM) * 20;

    localparam int N_PALAVRAS = 1024;
    logic [31:0] imagem [0:N_PALAVRAS-1];

    string caminho_imagem;
    string caminho_saida;
    integer fd;
    integer i;
    logic trace_ativo = 1'b0;
    logic trace_habilitado; // ligado via +TRACE (opcional, so para depuracao)

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
