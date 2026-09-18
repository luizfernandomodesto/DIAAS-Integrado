`timescale 1ns / 1ps

// Manda várias amostras pro hardware numa simulação só.
// INJECAO_DIRETA: 0 = pela UART, como na placa. 1 = direto no filtro, 4x mais rápido.
module tb_acelerador_streaming #(
    parameter bit INJECAO_DIRETA = 0
);

    localparam int NUMTAPS = 127;
    // Baud só da simulação. Com poucos ciclos por bit o byte sai corrompido.
    localparam int CICLOS_POR_BIT = 8;
    localparam int TAXA_BAUD_SIM  = 50_000_000 / CICLOS_POR_BIT;
    localparam int TEMPO_BIT      = CICLOS_POR_BIT * 20;
    localparam int TETO_ESPERA    = NUMTAPS + 50;

    logic clk;
    logic rst_n;
    logic rx;
    logic tx;
    logic limpa_buffer;
    logic        inj_valido;
    logic [31:0] inj_dado;

    acelerador_streaming_top #(
        .TAXA_BAUD(TAXA_BAUD_SIM),
        .NUMTAPS(NUMTAPS),
        .INJECAO_DIRETA(INJECAO_DIRETA)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .rx(rx),
        .inj_valido(inj_valido),
        .inj_dado(inj_dado),
        .limpa_buffer(limpa_buffer),
        .tx(tx)
    );

    always #10 clk = ~clk; // clock de 50MHz

    // Manda 1 byte pela UART simulada (bit de start, 8 bits, bit de stop)
    task envia_byte_serial(input logic [7:0] dado);
        begin
            @(posedge clk); // alinha o bit de start a borda de clock
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

    // Entrega uma palavra de 32 bits ao filtro, pelo modo escolhido
    task entrega_palavra(input logic [31:0] palavra);
        begin
            if (INJECAO_DIRETA) begin
                @(posedge clk);
                inj_dado   = palavra;
                inj_valido = 1'b1;
                @(posedge clk);
                inj_valido = 1'b0;
            end else begin
                envia_byte_serial(palavra[31:24]);
                envia_byte_serial(palavra[23:16]);
                envia_byte_serial(palavra[15:8]);
                envia_byte_serial(palavra[7:0]);
            end
        end
    endtask

    integer fd_entrada, fd_saida;
    logic [31:0] amostra;
    integer total_amostras;
    integer ciclos_espera;
    logic   viu_pronto;

    string caminho_amostras;
    string caminho_saida;
    // +LIMPA_CADA=N zera o histórico a cada N amostras. 0 = nunca limpa.
    integer limpa_cada;

    initial begin
        // Le os dois argumentos: arquivo de entrada e onde escrever a saida
        if (!$value$plusargs("AMOSTRAS=%s", caminho_amostras)) begin
            $display("ERRO: use +AMOSTRAS=arquivo.hex");
            $finish;
        end
        if (!$value$plusargs("SAIDA=%s", caminho_saida)) begin
            $display("ERRO: use +SAIDA=arquivo.txt");
            $finish;
        end

        // Reseta o hardware antes de comecar
        clk          = 0;
        rst_n        = 0;
        rx           = 1;
        limpa_buffer = 0;
        inj_valido   = 0;
        inj_dado     = 32'd0;
        if (!$value$plusargs("LIMPA_CADA=%d", limpa_cada)) begin
            limpa_cada = 0;
        end
        #100;
        rst_n = 1;
        #100;

        fd_entrada = $fopen(caminho_amostras, "r");
        if (fd_entrada == 0) begin
            $display("ERRO: nao consegui abrir %s", caminho_amostras);
            $finish;
        end
        fd_saida = $fopen(caminho_saida, "w");
        if (fd_saida == 0) begin
            $display("ERRO: nao consegui abrir %s para escrita", caminho_saida);
            $finish;
        end

        // Le uma amostra por linha, manda pro hardware, espera o resultado
        total_amostras = 0;
        while ($fscanf(fd_entrada, "%h\n", amostra) == 1) begin
            entrega_palavra(amostra);

            // Laço com flag: o Verilator não tem disable fork, o Icarus não tem break.
            ciclos_espera = 0;
            viu_pronto    = 1'b0;
            while (!viu_pronto) begin
                @(posedge clk);
                if (dut.fsm_inst.resultado_pronto) begin
                    viu_pronto = 1'b1;
                end else begin
                    ciclos_espera = ciclos_espera + 1;
                    if (ciclos_espera > TETO_ESPERA) begin
                        $display("ERRO: timeout esperando resultado_pronto (amostra %0d)",
                                 total_amostras);
                        $finish;
                    end
                end
            end

            $fwrite(fd_saida, "%0d\n", $signed(dut.fio_acumulador));
            total_amostras = total_amostras + 1;

            // Fim de um canal: zera o historico antes do proximo comecar
            if (limpa_cada > 0 && (total_amostras % limpa_cada) == 0) begin
                @(posedge clk);
                limpa_buffer = 1'b1;
                @(posedge clk);
                limpa_buffer = 1'b0;
                @(posedge clk);
            end
        end

        $fclose(fd_entrada);
        $fclose(fd_saida);
        $display("OK: %0d amostras processadas, resultados em %s",
                 total_amostras, caminho_saida);
        $finish;
    end

endmodule
